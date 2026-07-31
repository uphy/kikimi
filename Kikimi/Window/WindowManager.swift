import AppKit
import Combine
import Foundation
import OSLog

// MARK: - WindowRestorationPlan

/// Pure decision logic for `WindowManager.launch()`'s startup window restoration (`docs/design/
/// 06-ui-panels.md` section 9). Factored out of `WindowManager` itself so it is directly
/// unit-testable against fixture `KikimiStateData` values without touching `AppState`/
/// `SessionStore`/AppKit — the same pattern `TranscriptRowList`
/// (`Kikimi/ViewModels/TranscriptRowList.swift`) and `SessionListGrouping`
/// (`Kikimi/ViewModels/SessionListViewModel.swift`) already use for their own pure cores.
enum WindowRestorationPlan {
    /// Session ids to recreate a Session Window window for at launch. Only `visible == true`
    /// entries get an actual window; `visible == false` entries are position/size/tab memory only
    /// and are intentionally left alone (section 9, "ウィンドウの表示条件": "`visible == false` の
    /// エントリは位置・サイズ・`activeTab` の記憶だけを保持し、ウィンドウは生成しない（メモリ・
    /// 起動時間の節約）"). Preserves `state.windows`' on-disk order.
    static func sessionIdsToRestore(from state: KikimiStateData) -> [String] {
        state.windows.filter(\.visible).map(\.sessionId)
    }
}

// MARK: - WindowManager

/// The single `@MainActor` hub that owns every Kikimi window (`docs/design/06-ui-panels.md` section
/// 5.2, kikimi.md 13 章's `WindowManager.shared` component). Creates/shows/restores/destroys the
/// three window kinds (Session Window / Session List / Settings, kikimi.md 10 章) and is the
/// sole Main Actor distribution point for `SessionStore`'s Recording-exclusivity flag: `SessionStore`
/// is an `actor` and cannot itself hold a `@Published` property observable from arbitrary Main Actor
/// contexts, so every `MeetingWorkspaceViewModel` observes `WindowManager.shared.$recordingSessionId`
/// instead of `SessionStore.shared.recordingSessionId` directly (section 5.2).
///
/// Unlike Chirami's `WindowManager` (`docs/references/chirami-map.md` section 3), which manages
/// long-lived note windows keyed by `noteId` for the app's entire run, this type's
/// `workspaceControllers` entries are transient: a window is discarded (not merely hidden) the
/// moment it closes (section 2's Chirami-diff table), and reopening the same session later
/// constructs a brand-new `MeetingWorkspaceWindowController`/`MeetingWorkspaceViewModel` pair from
/// its `SessionHandle`.
@MainActor
final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    /// The currently Recording session id, kept in sync with `SessionStore.shared
    /// .subscribeToRecordingSessionId()` for the lifetime of the app (started once by `launch()`).
    /// See the type doc comment above for why this exists as a separate Main Actor publication
    /// point rather than every observer subscribing to `SessionStore` directly.
    @Published private(set) var recordingSessionId: String?

    /// `docs/design/18-recording-window-stow-and-compact.md` §4.2/§5.1: the menu bar's derived
    /// display state. `let`, not `private` -- `KikimiApp`'s `MenuBarLabelView` observes this
    /// instance directly for the lifetime of the app. **Not** observed by `MenuBarMenuView` -- see
    /// `menuBarMenu` below for why the menu body needs a separate publication point.
    let menuBarStatus = MenuBarStatusModel()

    /// `docs/design/18-recording-window-stow-and-compact.md` §4.2/§3.3/§6 failure mode #15: the
    /// menu **body**'s own publication point, deliberately a separate `ObservableObject` instance
    /// from `menuBarStatus` (not an extra `@Published` property on the same object) and fed a
    /// `timerText`-free projection (`MenuBarMenuContent.derive`) that only publishes when it
    /// actually changes (`MenuBarMenuModel.update`'s own de-dup guard). Recording's once-a-second
    /// elapsed-time tick recomputes `menuBarStatus` every second, and `MenuBarExtra(.menu)`
    /// re-evaluates (rebuilding its `NSMenu` and losing the user's current hover) any time an
    /// object it observes fires `objectWillChange` while the menu is open -- so `MenuBarMenuView`
    /// must observe this instance instead of `menuBarStatus`.
    let menuBarMenu = MenuBarMenuModel()

    /// `docs/design/41-meeting-profiles.md` §3.3/§6.2: the menu bar's cached meeting-profile list,
    /// fed into `MenuBarMenuContent.derive(from:profiles:)` by `publish(_:)` below. Deliberately
    /// **not** `@Published` -- propagation to the menu bar goes through the existing
    /// `recomputeMenuBarStatus()` -> `MenuBarMenuContent.derive` -> `MenuBarMenuModel.update`
    /// pipeline (§4.2/§6.2), not a second observation point on `WindowManager` itself. Only
    /// `refreshProfileMenu()` (`WindowManager+Profiles.swift`, split out for `file_length`) writes
    /// this, at the three defined refresh points (§6.2: 起動時 / 保存シート完了後 / Settings
    /// プロファイルタブの rename・delete 後) -- never read synchronously off disk from
    /// `MenuBarMenuContent.derive`'s pure body, since `MeetingProfileStore.list()` is `async` on an
    /// actor and cannot be called from a synchronous SwiftUI `body`.
    ///
    /// Not `private(set)` (unlike most of this type's other state): `private`'s file-scoping would
    /// block `WindowManager+Profiles.swift`'s writes, matching the same "not `private`, a sibling
    /// file needs it" carve-out `SessionStore.swift`'s `sessionsRootDirectory`/etc. use for
    /// `SessionStore+Defaults.swift`.
    var profileMenuItems: [MenuBarMenuContent.ProfileItem] = []

    /// One controller per currently open Session Window window, keyed by `sessionId`. A given
    /// session never has two windows open simultaneously (section 5.2: "同一セッションに対して二重に
    /// ウィンドウが開くことはない").
    private var workspaceControllers: [String: MeetingWorkspaceWindowController] = [:]
    /// Single cached instance, lazily created on first use (section 7).
    private var sessionListController: SessionListWindowController?
    /// Single cached instance, lazily created on first use (section 8).
    private var settingsController: SettingsWindowController?
    /// Single cached instance, lazily created on first use (`docs/design/29-dictation-history.md`
    /// section 6.1, DH8).
    private var dictationHistoryController: DictationHistoryWindowController?
    /// Single cached instance, lazily created on first use, matching the pattern above -- the
    /// メニューバー "用語を登録…" quick-add form (`GlossaryQuickAddWindowController`).
    private var glossaryQuickAddController: GlossaryQuickAddWindowController?

    /// `docs/design/40-diagram-zoom.md` DZ5: one instance for the whole app, created on first zoom
    /// and kept afterwards so the 3.3MB mermaid bundle is not reloaded every time.
    private var diagramZoomController: DiagramZoomWindowController?
    /// The long-lived subscription started once by `launch()`; see `startRecordingSubscription()`.
    private var recordingSubscriptionTask: Task<Void, Never>?

    /// Explicit "which sessions are currently stowed (`orderOut`'d)" tracking
    /// (`docs/design/18-recording-window-stow-and-compact.md` §3.3/§5.1), maintained by every
    /// stow/show/close/delete path below rather than probed via `window?.isVisible` -- keeps the
    /// menu's "〜 を表示" list's notion of "stowed" an explicit, intentional concept instead of an
    /// implicit property of window state. Insertion order (Recording session sorted first at read
    /// time by `hiddenWindowItems()`).
    private var stowedSessionIds: [String] = []
    /// `docs/design/18-recording-window-stow-and-compact.md` §4.2: the Recording session's
    /// `$recordingButtonState`/`$banners`/`$meta` subscriptions feeding `menuBarStatus`. Rebuilt --
    /// fully discarded and reconstructed -- every time `recordingSessionId` changes (including to
    /// `nil`, which simply empties this set), so no stale subscription to a no-longer-Recording
    /// session's view model can ever leak a strong reference to it.
    private var recordingStatusCancellables: Set<AnyCancellable> = []

    private let sessionStore: SessionStore
    private let appState: AppState
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "WindowManager")

    /// `.shared`-only by design: every other module written against this type so far
    /// (`SessionListViewModel`, `MeetingWorkspaceWindowController`) calls `WindowManager.shared`
    /// directly rather than taking an injected instance, matching `docs/design/06-ui-panels.md`
    /// section 5.2's `private init() {}`. `sessionStore`/`appState` are still stored (rather than
    /// referencing `.shared` inline at every call site below) purely so this type reads the same
    /// way `SessionStore`/`AppState` themselves are conventionally consumed elsewhere in this
    /// module, not as a testability seam.
    private init() {
        self.sessionStore = .shared
        self.appState = .shared
    }

    // MARK: 起動時

    /// Call exactly once, from `AppDelegate.applicationDidFinishLaunching` (section 5.2/9):
    /// 1. Starts the `recordingSessionId` subscription (idempotent; safe even if called more than
    ///    once, though callers should not rely on that).
    /// 2. Kicks off `refreshProfileMenu()` (`docs/design/41-meeting-profiles.md` §6.2's 起動時 refresh
    ///    point), so the menu bar's プロファイル submenu is populated without waiting for a later
    ///    save/rename/delete.
    /// 3. Checks `SessionStore.detectIncompleteSessions()`; if any are found, opens the Session List
    ///    window with its crash-recovery banner populated (section 7/9).
    /// 4. Restores every `AppState.shared.data.windows` entry with `visible == true`
    ///    (`WindowRestorationPlan`, above). A restoration target whose session folder no longer
    ///    exists (`.sessionNotFound`, e.g. manually deleted while the app was quit) is skipped with
    ///    a `.warning` log rather than surfaced to the user — there is no UI to surface it to at
    ///    this point in startup (section 9, failure mode #6's "起動時復元は `.warning`").
    func launch() async {
        startRecordingSubscription()
        // `docs/design/41-meeting-profiles.md` §6.2: one of the three defined `profileMenuItems`
        // refresh points (the other two are the プロファイル保存シート and the Settings プロファイル
        // タブ's rename/delete, both outside this type).
        refreshProfileMenu()

        let incompleteSessions = await sessionStore.detectIncompleteSessions()
        if !incompleteSessions.isEmpty {
            presentSessionList(incompleteSessions: incompleteSessions)
        }

        for sessionId in WindowRestorationPlan.sessionIdsToRestore(from: appState.data) {
            do {
                try await openWorkspace(sessionId: sessionId)
            } catch SessionStoreError.sessionNotFound {
                logger.warning(
                    "Skipping restoration of session \(sessionId, privacy: .public): its session folder no longer exists"
                )
            } catch {
                logger.error(
                    "Failed to restore the workspace window for session \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: Session Window

    /// Opens (or, if already open, simply fronts) the Session Window window for `sessionId`
    /// (section 5.2: "既存があれば showWindow"). Throws `.sessionNotFound` (via
    /// `SessionStore.openSession(_:)`) if the session folder does not exist.
    @discardableResult
    func openWorkspace(sessionId: String) async throws -> MeetingWorkspaceWindowController {
        if let existing = workspaceControllers[sessionId] {
            // `docs/design/18-recording-window-stow-and-compact.md` §4.3/§5.1: funnels through
            // `showWorkspaceWindow(sessionId:)` (rather than the bare `existing.showWindow(nil)` this
            // used to call directly) so the `visible = true` write-back is a single, shared code path
            // for every re-display route -- this one included.
            showWorkspaceWindow(sessionId: sessionId)
            return existing
        }

        let handle = try await sessionStore.openSession(sessionId)
        let viewModel = MeetingWorkspaceViewModel(sessionHandle: handle)
        let controller = MeetingWorkspaceWindowController(viewModel: viewModel)
        workspaceControllers[sessionId] = controller
        controller.showWindow(nil)
        return controller
    }

    /// Creates a new Draft session seeded per `seed` -- global defaults / an existing session's
    /// `context.md`/`summary_template.md`/watchers/participants / a saved meeting profile
    /// (`docs/design/41-meeting-profiles.md` §3.1/§4) -- and opens its Session Window (kikimi.md
    /// 10 章 "+ 新規" / "複製して新規セッション" / プロファイルから新規, `kikimi://window/new[?based_on=|
    /// ?profile=]`). Generalizes the previous `createDraftWorkspace(basedOn:)` (§3.3).
    ///
    /// `SessionStore.createDraftSession(seed:)` never fails outright over an unresolved `.profile`
    /// seed -- it soft-falls-back to global defaults and reports that fact as data
    /// (`DraftCreationResult.appliedSeed == .profileFallback`, §4's "黙って間違った準備で始まるのを
    /// 防ぐ"). `SessionStore` itself never touches any UI surface, so translating that data into
    /// something visible is this method's job: once the fallback Draft's Session Window is open, its
    /// `MeetingWorkspaceViewModel.banners` gets a `WorkspaceBanner.profileFallback` appended,
    /// consolidating every seed-my-Draft-from-a-profile entry point (Session List pulldown, menu bar
    /// submenu, `?profile=` URL scheme) onto the single Session Window banner surface (§6.5).
    @discardableResult
    func createDraftWorkspace(seed: DraftSeed = .none) async throws -> MeetingWorkspaceWindowController {
        let result = try await sessionStore.createDraftSession(seed: seed)
        let controller = try await openWorkspace(sessionId: result.meta.id)
        if case .profileFallback(let requestedId) = result.appliedSeed {
            controller.viewModel.banners.append(.profileFallback(requestedProfileId: requestedId))
        }
        return controller
    }

    /// `kikimi://record/quick` (section 5.2, kikimi.md 10 章): creates a new default-context Draft
    /// and starts recording immediately. If another session is already recording, throws
    /// `.anotherSessionRecording` **without creating a new Draft/window at all** — kikimi.md 10 章
    /// is explicit that this entry point must prioritize the existing Recording session over the
    /// new request, to avoid an unintended disconnect (section 11, failure mode #13).
    @discardableResult
    func quickRecord() async throws -> MeetingWorkspaceWindowController {
        if let activeSessionId = recordingSessionId {
            logger.warning(
                "Ignored kikimi://record/quick: session \(activeSessionId, privacy: .public) is already recording"
            )
            throw SessionStoreError.anotherSessionRecording(activeSessionId: activeSessionId)
        }

        let controller = try await createDraftWorkspace()
        await controller.viewModel.startRecording()
        return controller
    }

    /// Called by `MeetingWorkspaceWindowController.windowWillClose(_:)` (section 9). Only marks the
    /// `AppState` entry `visible = false` and drops the controller from `workspaceControllers`; the
    /// session folder and its `AppState` entry both survive so the session can be reopened later
    /// (section 5.2). By the time this is reachable, `windowShouldClose` has already guaranteed the
    /// session is not Recording (section 9: "Recording 中はクローズ自体をブロックする...ここに到達する
    /// 時点で Recording 中ではないことが保証されている").
    func workspaceWindowDidClose(sessionId: String) {
        appState.markWindowHidden(sessionId: sessionId)
        workspaceControllers.removeValue(forKey: sessionId)
        stowedSessionIds.removeAll { $0 == sessionId }
        recomputeMenuBarStatus()
    }

    // MARK: Session Window: しまう / 表示 (`docs/design/18-recording-window-stow-and-compact.md` §3.2/§5.1)

    /// "しまう" (§3.2/R1): hides the window via `MeetingWorkspaceWindowController.stow()` --
    /// `orderOut`, not `close()` -- so the controller/view model/recording pipeline all survive in
    /// `workspaceControllers`. A no-op (with a `.warning` log) if no controller is open for
    /// `sessionId`; never writes to `AppState` in that case.
    func stowWorkspaceWindow(sessionId: String) {
        guard let controller = workspaceControllers[sessionId] else {
            logger.warning(
                "stowWorkspaceWindow(sessionId:) called with no open controller for \(sessionId, privacy: .public); ignoring"
            )
            return
        }
        controller.stow()
        if !stowedSessionIds.contains(sessionId) {
            stowedSessionIds.append(sessionId)
        }
        recomputeMenuBarStatus()
    }

    /// The single re-display entry point (§3.2's table: menu bar / Session List "開く" / R6's
    /// auto-reshow all funnel through this) -- fronts the window and upserts `AppState`'s
    /// `visible = true` (§4.3). The **controller-not-found guard is load-bearing, not merely
    /// defensive** (§5.1): a delayed call after the window was actually closed (or a unit test
    /// driving `endMeeting()` directly with this wired) must never touch the real `state.yaml`.
    /// Idempotent if the window is already shown (§6 failure mode #9).
    func showWorkspaceWindow(sessionId: String) {
        guard let controller = workspaceControllers[sessionId] else {
            logger.warning(
                "showWorkspaceWindow(sessionId:) called with no open controller for \(sessionId, privacy: .public); ignoring"
            )
            return
        }
        controller.unstow()
        stowedSessionIds.removeAll { $0 == sessionId }
        recomputeMenuBarStatus()
    }

    // MARK: メニューバー: 会議を終了 (`docs/design/18-recording-window-stow-and-compact.md` §3.3/§5.1)

    /// The menu bar's "会議を終了…" item (Recording-only, §3.3). Unlike the header's `⏹` (which needs
    /// no confirmation -- the user is already looking at the window's own content), this route is
    /// reachable with no window context in view, so it always confirms first via an app-modal
    /// `NSAlert.runModal()` -- the same synchronous-alert-before-any-`Task` pattern
    /// `AppDelegate.applicationShouldTerminate` uses (`Kikimi/KikimiApp.swift`).
    func endRecordingMeetingFromMenuBar() {
        guard let recordingSessionId, let controller = workspaceControllers[recordingSessionId] else {
            logger.warning("endRecordingMeetingFromMenuBar() called with no active Recording session; ignoring")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "会議を終了しますか？"
        alert.informativeText = "サマリの確定と Wiki export が実行されます。"
        alert.addButton(withTitle: "会議を終了")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // §6 failure mode #12: re-check after the (synchronous, blocking) alert -- the session may
        // have been paused/ended/superseded by another session while it was on screen.
        // `recordingSessionId` itself already goes `nil` (or changes to a different session) the
        // moment this one stops Recording (`SessionStore.pauseRecording`/`endMeeting` both clear it,
        // `Kikimi/SessionStore/SessionStore.swift`), so comparing against the id captured above is
        // enough to detect every one of those cases without re-deriving `recordingButtonState`.
        // Guards against a double `endMeeting()` call the same way.
        guard self.recordingSessionId == recordingSessionId else {
            logger.warning(
                "endRecordingMeetingFromMenuBar() approved, but session \(recordingSessionId, privacy: .public) is no longer Recording; ignoring"
            )
            return
        }

        Task { @MainActor in
            await controller.viewModel.endMeeting()
        }
    }

    // MARK: Session List / Settings

    func showSessionList() {
        presentSessionList(incompleteSessions: [])
    }

    func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.show()
    }

    /// `docs/design/29-dictation-history.md` section 6.1 (DH8): single cached instance, lazily
    /// created on first use, matching `showSettings()` immediately above.
    func showDictationHistory() {
        if dictationHistoryController == nil {
            dictationHistoryController = DictationHistoryWindowController()
        }
        dictationHistoryController?.show()
    }

    /// メニューバー "用語を登録…": single cached instance, lazily created on first use, matching
    /// `showSettings()`/`showDictationHistory()` immediately above.
    func showGlossaryQuickAdd() {
        if glossaryQuickAddController == nil {
            glossaryQuickAddController = GlossaryQuickAddWindowController()
        }
        glossaryQuickAddController?.show()
    }

    /// The zoom button on a rendered mermaid diagram (`docs/design/40-diagram-zoom.md`). `anchor` is
    /// the window the diagram was clicked in, which decides the screen the overlay covers (DZ2).
    func showDiagramZoom(source: String, anchoredTo anchor: NSWindow?) {
        if diagramZoomController == nil {
            diagramZoomController = DiagramZoomWindowController()
        }
        diagramZoomController?.show(source: source, anchoredTo: anchor)
    }

    /// Resolves a `kikimi://debug/webview` target to the host that can answer it
    /// (`docs/design/39-webview-markdown.md` MD12). `nil` when no such web view exists yet — the
    /// tab was never opened, or the overlay has never been shown.
    ///
    /// For the three in-window surfaces, the key window wins so that a verification run driving two
    /// sessions talks to the one it just brought forward; with no key window it falls back to the only
    /// open workspace (the usual case under `kikimi-verify`).
    func debugWebViewHost(target: KikimiURLRoute.DebugWebViewTarget) -> MarkdownWebViewHost? {
        if case .diagram = target {
            return diagramZoomController?.host
        }

        let slot: MarkdownWebViewStore.Slot
        switch target {
        case .summary: slot = .summary
        case .watchers: slot = .watchers
        case .chat: slot = .chat
        case .diagram: return nil
        }

        let controller = workspaceControllers.values.first { $0.window?.isKeyWindow == true }
            ?? workspaceControllers.values.first
        return controller?.markdownWebViewStore.existingHost(for: slot)
    }

    /// "削除" (section 5.2/7, failure mode #5). Closes the session's Session Window window if it
    /// is open — bypassing the Recording close-confirmation dialog via `NSWindowController.close()`
    /// rather than `performClose(_:)`, since `SessionListViewModel.delete(sessionId:)` only calls
    /// this after `SessionStore.deleteSession(_:)` has already succeeded, which itself refuses to
    /// delete an actively-recording session (`.cannotDeleteActiveRecording`) — so by construction
    /// there is nothing left to confirm. Also drops the `AppState` entry entirely (as opposed to
    /// `workspaceWindowDidClose`'s `markWindowHidden`, which keeps it around for reopening).
    func handleSessionDeleted(sessionId: String) {
        workspaceControllers[sessionId]?.close()
        workspaceControllers.removeValue(forKey: sessionId)
        appState.removeWindowState(sessionId: sessionId)
        stowedSessionIds.removeAll { $0 == sessionId }
        recomputeMenuBarStatus()
    }

    // MARK: アプリ終了シーケンス（9章）

    /// Call from `AppDelegate.applicationShouldTerminate` once the user has confirmed termination
    /// (section 9). Waits for the actively-recording session's `pauseRecording()` to finish (so the
    /// final WAV header/`meta.json` write-back completes before the process exits), then flushes
    /// every currently open window's `SessionHandle` in parallel. The caller is responsible for
    /// racing this against a timeout (section 9's 5-second `withTaskGroup`/`Task.sleep` example) —
    /// this method itself has no timeout, matching the design doc's `WindowManager
    /// .prepareForTermination()` contract, which delegates the timeout entirely to the caller.
    ///
    /// Pauses rather than ends the meeting (kikimi.md 4 章): quitting the app is not the user
    /// deciding the meeting is over, so `on_session_end` must not run here. The session is left
    /// `.paused` and resumable/endable next launch, same as a crash-recovered session.
    func prepareForTermination() async {
        if let recordingSessionId, let recordingController = workspaceControllers[recordingSessionId] {
            logger.info("Pausing the active recording session \(recordingSessionId, privacy: .public) before terminating")
            await recordingController.viewModel.pauseRecording()
        }

        await withTaskGroup(of: Void.self) { group in
            for controller in workspaceControllers.values {
                group.addTask { await controller.viewModel.flushSessionHandle() }
            }
        }
    }

    // MARK: Private helpers

    /// Starts (once) the long-lived subscription that keeps `recordingSessionId` in sync with
    /// `SessionStore.shared.subscribeToRecordingSessionId()` (section 5.2). Idempotent: a second
    /// call while a subscription is already running is a no-op, so `launch()` can be called
    /// defensively without risking two competing subscriptions.
    private func startRecordingSubscription() {
        guard recordingSubscriptionTask == nil else { return }
        recordingSubscriptionTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.sessionStore.subscribeToRecordingSessionId()
            for await value in stream {
                if Task.isCancelled { return }
                self.recordingSessionId = value
                // `docs/design/18-recording-window-stow-and-compact.md` §4.2: every
                // `recordingSessionId` transition (including to `nil`) fully discards and rebuilds
                // the Recording session's menu-bar-feeding subscriptions.
                self.rebuildRecordingStatusSubscriptions()
            }
        }
    }

    // MARK: Menu bar status (`docs/design/18-recording-window-stow-and-compact.md` §4.2)

    /// Discards every previous Recording-session subscription and, if a session is currently
    /// Recording *and* its controller is open, subscribes afresh to its `$recordingButtonState`/
    /// `$banners`/`$meta` -- each of which recomputes the full `menuBarStatus` on every emission
    /// (§4.2: `$meta` specifically covers "しまっている間に自動タイトル命名が走る", §6 failure mode
    /// #14, so a stowed Recording session's stale title never lingers in the "〜 を表示" menu item).
    /// Emptying `recordingStatusCancellables` first is what prevents a strong reference to a
    /// no-longer-Recording session's view model from leaking for the rest of `WindowManager`'s
    /// (singleton, app-lifetime) existence.
    private func rebuildRecordingStatusSubscriptions() {
        recordingStatusCancellables.removeAll()

        guard let recordingSessionId, let controller = workspaceControllers[recordingSessionId] else {
            recomputeMenuBarStatus()
            return
        }

        let viewModel = controller.viewModel
        viewModel.$recordingButtonState
            .sink { [weak self] _ in self?.recomputeMenuBarStatus() }
            .store(in: &recordingStatusCancellables)
        viewModel.$banners
            .sink { [weak self] _ in self?.recomputeMenuBarStatus() }
            .store(in: &recordingStatusCancellables)
        viewModel.$meta
            .sink { [weak self] _ in self?.recomputeMenuBarStatus() }
            .store(in: &recordingStatusCancellables)
    }

    /// Rebuilds `menuBarStatus.status` from scratch via `MenuBarStatus.derive` -- this method's only
    /// job is gathering the derive's inputs (§4.2: "derive への入力を集めるだけで、判定は
    /// `MenuBarStatus.derive` に委譲する"). Called after every event that could change any of them:
    /// a `recordingSessionId` transition, a stow/show/close/delete, or (via
    /// `rebuildRecordingStatusSubscriptions()`'s subscriptions) a change to the Recording session's
    /// `recordingButtonState`/`banners`/`meta`. Also the republish step `refreshProfileMenu()`
    /// (`WindowManager+Profiles.swift`) calls once `profileMenuItems` is updated -- not `private` for
    /// that reason (same file-scoping carve-out as `profileMenuItems` above).
    func recomputeMenuBarStatus() {
        guard let recordingSessionId, let controller = workspaceControllers[recordingSessionId] else {
            publish(
                MenuBarStatus.derive(
                    isRecording: false,
                    elapsedSeconds: nil,
                    recordingTitle: nil,
                    recordingHasWarning: false,
                    hiddenWindows: hiddenWindowItems()
                )
            )
            return
        }

        let viewModel = controller.viewModel
        let elapsedSeconds: Int?
        let isRecording: Bool
        if case .recording(let seconds) = viewModel.recordingButtonState {
            isRecording = true
            elapsedSeconds = seconds
        } else {
            isRecording = false
            elapsedSeconds = nil
        }

        publish(
            MenuBarStatus.derive(
                isRecording: isRecording,
                elapsedSeconds: elapsedSeconds,
                recordingTitle: Self.displayTitle(viewModel.meta.title),
                recordingHasWarning: !viewModel.banners.isEmpty,
                hiddenWindows: hiddenWindowItems()
            )
        )
    }

    /// The single place `menuBarStatus`/`menuBarMenu` are ever written (§4.2: "`menuBarStatus.status`
    /// を更新した箇所で毎回 `MenuBarMenuContent.derive(from:)` を通して `menuBarMenu` にも流す").
    /// `menuBarStatus` always republishes verbatim (the label needs every tick, including
    /// `timerText`-only changes); `menuBarMenu` goes through `MenuBarMenuContent.derive` and its own
    /// de-dup guard (`MenuBarMenuModel.update`), which is what keeps a Recording session's
    /// once-a-second elapsed-time tick from ever reaching the open menu's `NSMenu`. `profileMenuItems`
    /// rides along on every call (not just the ones `refreshProfileMenu()` itself triggers) so a
    /// Recording-status-driven recompute never regresses the menu's プロファイル一覧 back to empty
    /// (`docs/design/41-meeting-profiles.md` §6.2).
    private func publish(_ status: MenuBarStatus) {
        menuBarStatus.update(status)
        menuBarMenu.update(MenuBarMenuContent.derive(from: status, profiles: profileMenuItems))
    }

    /// Every currently-stowed session's menu item (§3.3), Recording-session-first, in otherwise
    /// stable `stowedSessionIds` insertion order. Reads each session's *current* title directly off
    /// its still-alive controller/view model rather than caching one at stow time -- titles are
    /// always resolved fresh here, so this alone (no separate per-hidden-window subscription) is
    /// enough to answer `$meta`-changed staleness for the Recording session (a non-Recording, stowed
    /// session's title cannot change while Paused: no `SummaryUpdater` is running for it, kikimi.md
    /// 8 章's auto-naming only ever fires while Recording).
    private func hiddenWindowItems() -> [MenuBarStatus.HiddenWindowItem] {
        let orderedIds = stowedSessionIds.sorted { lhs, rhs in
            if lhs == recordingSessionId { return true }
            if rhs == recordingSessionId { return false }
            return false // Swift's Array.sort is stable: preserves stowedSessionIds' relative order.
        }
        return orderedIds.compactMap { sessionId in
            guard let controller = workspaceControllers[sessionId] else { return nil }
            return MenuBarStatus.HiddenWindowItem(
                id: sessionId,
                title: Self.displayTitle(controller.viewModel.meta.title)
            )
        }
    }

    /// Blank-title substitution shared by the Recording info row and every "〜 を表示" item
    /// (§3.3/§4.2, matching `MeetingWorkspaceTitleView`'s "無題の会議" fallback,
    /// `Kikimi/Views/MeetingWorkspace/MeetingWorkspaceView.swift`).
    private static func displayTitle(_ title: String) -> String {
        title.isEmpty ? "無題の会議" : title
    }

    /// Shared implementation behind `showSessionList()` and `launch()`'s crash-recovery path
    /// (section 7/9). `incompleteSessions` seeds the (necessarily freshly-constructed)
    /// `SessionListViewModel.incompleteSessionsBanner` at creation time, since
    /// `SessionListWindowController` does not expose its view model for later mutation once built.
    /// In practice this only matters the very first time `sessionListController` is created: by the
    /// time a user-triggered `showSessionList()` (which always passes `[]`) could race
    /// `launch()`'s crash-recovery call, `launch()` (section 5.2: "1回だけ呼ぶ") has always already
    /// run to completion during app startup.
    private func presentSessionList(incompleteSessions: [SessionMeta]) {
        if sessionListController == nil {
            let viewModel = SessionListViewModel()
            viewModel.incompleteSessionsBanner = incompleteSessions
            sessionListController = SessionListWindowController(viewModel: viewModel)
        }
        sessionListController?.show()
    }
}
