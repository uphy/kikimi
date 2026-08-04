import AppKit
import Combine
import SwiftUI
import OSLog

// MARK: - MeetingWorkspaceWindowController

/// Owns one Session Window floating window: hosts `MeetingWorkspaceView` on a `FloatingPanel`,
/// stows (rather than closes) the window while recording (`docs/design/06-ui-panels.md` section
/// 6.1.1, `docs/design/18-recording-window-stow-and-compact.md` §3.2), and persists window
/// position/size to `AppState` (section 9). One instance per open session, vended/owned by
/// `WindowManager.shared` (section 5.2's `workspaceControllers` dictionary) — this type is never
/// constructed by SwiftUI or by anything other than `WindowManager`.
///
/// `FloatingPanel`'s own doc comment states the window controller "remains responsible for
/// `title`, restoring saved position/size, and installing their content view" — this type is
/// that caller for the Session Window window kind specifically.
@MainActor
final class MeetingWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    /// Frame used the first time a session's window is ever opened (no prior
    /// `AppState.windowState(for:)` entry). Matches the size kikimi.md section 12's `state.yaml`
    /// sample uses for its first workspace window entry.
    private static let defaultFrame = NSRect(x: 100, y: 100, width: 800, height: 600)

    /// Debounce window for `windowDidMove`/`windowDidResize` → `AppState.upsertWindowState`
    /// persistence (section 9: "デバウンス（例: 300ms）してから保存"). `var` (not `let`) so tests can
    /// shrink it instead of sleeping 300ms per assertion — the same injectable-clock spirit as
    /// `SessionHandle`'s `metaFlushInterval`/`now` (`Kikimi/SessionStore/SessionHandle.swift`).
    var moveResizeDebounceNanoseconds: UInt64 = 300_000_000

    let sessionId: String
    let viewModel: MeetingWorkspaceViewModel

    private let appState: AppState
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "MeetingWorkspaceWindowController")

    private var moveResizeDebounceTask: Task<Void, Never>?

    /// `docs/design/18-recording-window-stow-and-compact.md` §5.1's "しまってあるかどうか" concept, local
    /// to this controller (mirrors `WindowManager.stowedSessionIds`'s app-wide equivalent, §5.1/§4.2).
    /// Toggled only by `stow()`/`unstow()` below; consulted by the `onMeetingEnded` closure wired in
    /// `init` (§5.1/§5.4) to decide whether R6's auto-reshow should actually fire.
    private var isStowed = false
    /// `docs/design/18-recording-window-stow-and-compact.md` §5.2: `true` while the window is in
    /// compact-pill form. Doubles as the persistence-suppression flag `scheduleWindowStateSave()`/
    /// `saveWindowState()` both guard on (R5) -- see `applyWindowMode(_:)`'s doc comment for the
    /// exact ordering bug this flag (and where it's flipped) exists to prevent.
    private var isCompact = false
    /// The window's frame immediately before the most recent compact-mode transition, captured by
    /// `applyWindowMode(.compact)` and consumed (then cleared) by `applyWindowMode(.normal)` (§5.2).
    /// `nil` whenever not compact.
    private var expandedFrame: NSRect?
    /// `docs/design/18-recording-window-stow-and-compact.md` §5.2's compact pill's fixed size.
    private static let compactPillSize = NSSize(width: 380, height: 44)
    /// Restored on `applyWindowMode(.normal)` -- matches this window's un-touched defaults (no
    /// `contentMinSize`/`contentMaxSize` was ever set before compact mode existed), so expanding
    /// simply undoes whatever compact mode constrained (§5.2's "NSHostingView の最小サイズ制約との
    /// 衝突を防ぐ" concern, in reverse).
    private static let defaultContentMinSize = NSSize(width: 0, height: 0)
    private static let defaultContentMaxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )
    /// `docs/design/18-recording-window-stow-and-compact.md` §5.2: subscribes to
    /// `viewModel.$windowMode` in `init` below.
    private var windowModeCancellable: AnyCancellable?

    /// The window's sole content view. Stored (not a fire-and-forget local in `init`) so
    /// `sizingOptions` can be neutralized right after construction -- see the property's own doc
    /// comment on why that's necessary.
    private let hostingView: NSHostingView<MeetingWorkspaceView>

    /// The window's Markdown web views (`docs/design/39-webview-markdown.md` MD2). Owned here so
    /// they survive SwiftUI rebuilding the view tree; released in `windowWillClose`. Not `private`
    /// so the verification bridge (MD12) can reach a specific surface's host.
    let markdownWebViewStore: MarkdownWebViewStore

    /// Keeps the native `NSWindow.title` (Window menu, Mission Control, etc.) in sync with
    /// `viewModel.meta.title` for the window's whole lifetime — the one-time `panel.title = ...`
    /// assignment in `init` below only covers the initial (pre-hydration, always-empty)
    /// placeholder `meta` (`MeetingWorkspaceViewModel.placeholderMeta(sessionId:)`); without this
    /// subscription every Session Window window stays natively untitled forever, even after
    /// `hydrateFromSessionHandle()` loads the real title or the user renames it.
    private var metaTitleCancellable: AnyCancellable?

    /// - Parameters:
    ///   - viewModel: The already-constructed view model for the session this window shows.
    ///     Ownership is shared with `WindowManager` (which vends this controller); the controller
    ///     never constructs or replaces it.
    ///   - appState: Injectable for testability, same pattern as `AppState.init(directory:)`
    ///     itself (`docs/design/06-ui-panels.md` section 5.1) and `SessionHandle`'s injectable
    ///     dependencies. Production call sites rely on the default and always get `AppState.shared`.
    init(viewModel: MeetingWorkspaceViewModel, appState: AppState = .shared) {
        self.sessionId = viewModel.sessionId
        self.viewModel = viewModel
        self.appState = appState

        let savedState = appState.windowState(for: viewModel.sessionId)
        let frame = Self.frame(from: savedState)
        let panel = FloatingPanel(contentRect: frame)
        panel.title = viewModel.meta.title
        panel.isRestorable = false

        // `docs/design/39-webview-markdown.md` MD2: the Markdown web views are owned here, for the
        // window's whole lifetime. SwiftUI tears its representables down on a tab switch (measured
        // in Phase A0, §11), so a web view created inside the view tree would re-parse its bundle
        // and lose its scroll position every time the user came back to the tab.
        let markdownWebViewStore = MarkdownWebViewStore()
        self.markdownWebViewStore = markdownWebViewStore

        let hostingView = FirstMouseHostingView(
            rootView: MeetingWorkspaceView(viewModel: viewModel, markdownWebViewStore: markdownWebViewStore)
        )
        // `NSHostingView`'s default `sizingOptions` is `[.minSize, .intrinsicContentSize, .maxSize]`
        // (macOS 13+): the hosting view probes its SwiftUI content and installs Auto Layout
        // constraints back onto itself (and, transitively, the window) that push the *window*'s
        // frame to match the content's ideal/min/max size. That fights every manual `setFrame` call
        // this controller makes -- both `applyCompactMode()`'s 380x44 pill frame (observed inflating
        // to ~480x179, with the pill content correctly laid out but pinned to the bottom of a too-tall
        // window) and `applyNormalMode()`'s restore of `expandedFrame` (observed drifting +11pt taller
        // than the frame that was actually saved, since the *normal* layout's own intrinsic min-height
        // constraint was still ~11pt taller than the saved height and won the fight). This controller
        // already manages the window's frame entirely by hand (saved/default frame in `init`,
        // `contentMinSize`/`contentMaxSize` + `setFrame` in `applyCompactMode`/`applyNormalMode`, and
        // free user resizing in normal mode), so there's nothing for `NSHostingView`'s own sizing
        // machinery to usefully contribute in either mode -- disable it outright rather than only
        // while compact, since the +11pt normal-mode drift traces to the exact same mechanism.
        hostingView.sizingOptions = []
        self.hostingView = hostingView

        super.init(window: panel)
        panel.delegate = self

        panel.contentView = hostingView

        // `$meta` emits its current value immediately upon subscription, so this also covers the
        // `panel.title = viewModel.meta.title` assignment above's case (still kept for clarity/as
        // a fallback in case `window` is ever nil at subscription time).
        metaTitleCancellable = viewModel.$meta
            .map(\.title)
            .removeDuplicates()
            .sink { [weak self] title in
                self?.window?.title = title
            }

        // `docs/design/18-recording-window-stow-and-compact.md` §5.2: `.dropFirst()` skips the
        // replayed *current* value `@Published` always delivers to a fresh subscriber -- without it,
        // this would fire once here in `init`, before `showWindow(nil)` has ever been called, and
        // `applyWindowMode(.normal)`'s trailing `saveWindowState()` would upsert a premature
        // `visible: false` entry (§5.2's own "既存の意味論が壊れる" warning). `.removeDuplicates()`
        // additionally skips any later same-value re-assignment (e.g. `endMeeting()` setting
        // `.normal` while already `.normal`), so `applyWindowMode` only ever runs on an actual change.
        windowModeCancellable = viewModel.$windowMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.applyWindowMode(mode)
            }

        // `docs/design/18-recording-window-stow-and-compact.md` §5.1/§5.4 (R6): the sole place this
        // seam is wired -- `MeetingWorkspaceViewModelTests` never sets it, so `endMeeting()` there has
        // zero window-visibility side effects. Fires only for a window still in compact-pill form at
        // the moment `endMeeting()` reached this point; an already-visible, normal window (ended via
        // the header's `⏹`, or via the menu bar's confirmed "会議を終了…", §3.3) and a stowed one are
        // both left alone -- see `shouldReshow`'s doc comment for why stowed no longer reveals. The
        // actual yes/no judgment is
        // `MeetingEndReshowDecision.shouldReshow(_:_:)`, a pure function factored out below so it's
        // unit-testable independent of this controller/`WindowManager` (§7 "R6 経路のレイヤ1テスト").
        viewModel.onMeetingEnded = { [weak self] sessionId in
            guard let self else { return }
            guard MeetingEndReshowDecision.shouldReshow(isStowed: self.isStowed, isCompact: self.isCompact) else { return }
            WindowManager.shared.showWorkspaceWindow(sessionId: sessionId)
        }

        // Restore the tab the user was last looking at (section 5.1: `WorkspaceWindowState
        // .activeTab` exists specifically "so reopening a session restores the tab the user was
        // last looking at"). `AppState` may only be touched here, not by `MeetingWorkspaceViewModel`
        // itself (section 3: "`AppState.shared` は `WindowManager` からのみ読み書きされる"), so this
        // controller -- not the view model's own `init` -- is responsible for applying it. Left
        // untouched (keeping the view model's own default) when there's no saved state yet.
        if let savedState {
            viewModel.activeTab = savedState.activeTab
            // `docs/design/17-session-window-redesign.md` §4.2/§4.4: restored the same way as
            // `activeTab` above, same "no saved state -> leave the view model's own default" rule.
            viewModel.meetingPaneMode = savedState.meetingPaneMode
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        moveResizeDebounceTask?.cancel()
    }

    private static func frame(from savedState: WorkspaceWindowState?) -> NSRect {
        guard let savedState else { return defaultFrame }
        return NSRect(x: savedState.x, y: savedState.y, width: savedState.width, height: savedState.height)
    }

    // MARK: - NSWindowDelegate: windowShouldClose (section 6.1.1)

    /// Draft/Ended closes for real (`WindowCloseDecision.allowClose`); Recording/Paused/
    /// pausedDisabledOtherRecording stows instead of closing, silently -- no confirmation dialog
    /// (`docs/design/18-recording-window-stow-and-compact.md` §3.2/R7); every other, transitional
    /// state denies the close and does nothing (`.denyTransient`, §2 R2).
    ///
    /// Routes the stow through `WindowManager.shared.stowWorkspaceWindow(sessionId:)` rather than
    /// calling `stow()` on `self` directly, so the "しまってあるウィンドウ一覧"/`menuBarStatus`
    /// bookkeeping that lives there (§5.1) stays in sync for this, the primary way a window ever
    /// gets stowed -- `stow()`'s own doc comment below states that invariant ("Only
    /// `WindowManager.stowWorkspaceWindow(sessionId:)` calls this").
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch WindowCloseDecision.evaluate(
            isStowable: viewModel.recordingButtonState.showsStowControls,
            blocksClose: viewModel.recordingButtonState.blocksWindowClose
        ) {
        case .allowClose:
            return true

        case .stowInsteadOfClose:
            WindowManager.shared.stowWorkspaceWindow(sessionId: sessionId)
            return false

        case .denyTransient:
            return false
        }
    }

    // MARK: - しまう / コンパクトモード (`docs/design/18-recording-window-stow-and-compact.md` §3.2/§5.2)

    /// "しまう" (§3.2/R1): hides the window via `orderOut` -- deliberately **not** `close()`/
    /// `performClose(_:)`, so `windowWillClose`/`workspaceWindowDidClose` never run and this
    /// controller (with its live `viewModel`/recording pipeline) survives in `WindowManager
    /// .workspaceControllers`. Only `WindowManager.stowWorkspaceWindow(sessionId:)` calls this.
    func stow() {
        // §3.2 step 0: expand from compact first (same `applyWindowMode(.normal)` path the [⤢]
        // button uses) so the "しまってある間はモード不変・再表示は常に通常表示" invariant holds --
        // runs synchronously, in the same run loop turn as `orderOut` below, so there's no visible
        // flicker (§6 failure mode #6).
        if isCompact {
            viewModel.windowMode = .normal
        }

        isStowed = true
        // §3.2 step 3 / §6 failure mode #8: cancel any in-flight debounced save first, same
        // precaution `windowWillClose` takes -- otherwise a stale `visible: true` write could land
        // after `markWindowHidden` below.
        moveResizeDebounceTask?.cancel()
        moveResizeDebounceTask = nil
        window?.orderOut(nil)
        appState.markWindowHidden(sessionId: sessionId)
    }

    /// Reverses `stow()`, and doubles as the single `visible = true` write-back path (§4.3) for
    /// every re-display route `WindowManager.showWorkspaceWindow(sessionId:)` funnels through (menu
    /// bar / Session List "開く" / R6's auto-reshow) -- calling `persistVisibleState()` once here is
    /// exactly the "upsert" §4.3 asks for: an existing `AppState` entry gets its `visible` field
    /// (among the rest, unchanged since the window wasn't moved while stowed) overwritten to `true`;
    /// a missing entry gets created fresh from the window's current frame/tab/pane-mode.
    ///
    /// Deliberately calls `persistVisibleState()`, **not** `saveWindowState()` (Minor-1 fix): the
    /// "開く" route above can target a window that's currently visible-but-compact rather than
    /// stowed (e.g. Session List "開く" on a session that's open and mid-compact but not the one
    /// Recording elsewhere) -- `saveWindowState()`'s `guard !isCompact` (R5) would then silently
    /// no-op the whole upsert, leaving a session with no prior `AppState` entry never getting one,
    /// which is exactly the gap §4.3 says to close. `persistVisibleState()` still honors R5 (it never
    /// writes the compact pill frame), it just doesn't skip the write entirely while compact.
    func unstow() {
        isStowed = false
        showWindow(nil)
        persistVisibleState()
    }

    /// §5.2's ordering-sensitive compact/normal toggle. `mode` is only ever a genuine change here
    /// (the `init`-time subscription already filtered out the replay/no-op cases via
    /// `.dropFirst().removeDuplicates()`).
    private func applyWindowMode(_ mode: WorkspaceWindowMode) {
        switch mode {
        case .compact:
            applyCompactMode()
        case .normal:
            applyNormalMode()
        }
    }

    /// §5.2: "この順序が必須". `isCompact = true` before cancelling the debounce task matters --
    /// `setFrame` triggers `windowDidResize` **synchronously**, gated by `scheduleWindowStateSave()`'s
    /// `isCompact` guard (R5).
    ///
    /// The final `setFrame` is deferred one main-run-loop turn (`resizeToPillFrameAfterSwiftUIReconciles`,
    /// below) rather than called here directly: shrinking synchronously, in the same call stack as
    /// `viewModel.windowMode = .compact`, squeezes the *old* header+`TabView` layout down to 380x44
    /// before `MeetingWorkspaceView`'s SwiftUI re-render onto `CompactRecordingBarView` has happened --
    /// `TabView`'s underlying `NSTabView` (real AppKit, unlike `CompactRecordingBarView`'s content) has
    /// its own Auto Layout minimum-size constraints that force the window back open to fit it, observed
    /// as the pill inflating to ~480x179 with content correctly laid out but pinned to the bottom of a
    /// too-tall window. Every other step (the flag, debounce cancel, `expandedFrame`, chrome swap)
    /// stays synchronous; only the geometry-mutating `setFrame` needs the extra turn.
    private func applyCompactMode() {
        guard !isCompact, let window else { return }
        isCompact = true
        moveResizeDebounceTask?.cancel()
        moveResizeDebounceTask = nil

        let previousFrame = window.frame
        expandedFrame = previousFrame
        applyChrome(compact: true)

        let pillSize = Self.compactPillSize
        window.contentMinSize = pillSize
        window.contentMaxSize = pillSize
        // §3.4: "コンパクト化時のピル位置は、直前の展開ウィンドウの左上角に揃える" -- same left edge (x),
        // top edge (maxY) held fixed while the frame shrinks downward from it.
        let pillOrigin = NSPoint(x: previousFrame.origin.x, y: previousFrame.maxY - pillSize.height)
        let pillFrame = NSRect(origin: pillOrigin, size: pillSize)
        resizeToPillFrameAfterSwiftUIReconciles(pillFrame)
    }

    /// Shrinks the window to `pillFrame` one main-run-loop turn from now, instead of immediately --
    /// see `applyCompactMode()`'s doc comment for why. `viewModel.windowMode` already reads `.compact`
    /// here (`@Published` notifies synchronously), but SwiftUI's own re-render of
    /// `MeetingWorkspaceView.body` onto `CompactRecordingBarView` lands on a *later* run-loop pass --
    /// verified empirically (`hostingView.subviews.count` still reflected the old, much larger
    /// normal-layout subtree at the point this used to run synchronously). `DispatchQueue.main.async`
    /// lets that pending SwiftUI update land first, so no `TabView`/`NSTabView` is left in the tree to
    /// fight the shrink. Guards `self`/`isCompact` since this now genuinely races a rapid
    /// compact -> normal round trip or the window closing before it runs.
    private func resizeToPillFrameAfterSwiftUIReconciles(_ pillFrame: NSRect) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCompact, let window = self.window else { return }
            window.setFrame(pillFrame, display: true)
        }
    }

    /// §5.2: chrome restore -> `setFrame` (screen-constrained) -> only *then* `isCompact = false` ->
    /// `saveWindowState()`. Keeping `isCompact` `true` through the `setFrame` call means any
    /// synchronous `windowDidResize` it triggers is still gated by `scheduleWindowStateSave()`'s
    /// guard; the explicit `saveWindowState()` call afterward is what actually persists the restored
    /// expanded frame (§5.2's "そのまま`saveWindowState()`を1回呼ぶ").
    private func applyNormalMode() {
        guard isCompact, let window else { return }
        applyChrome(compact: false)

        window.contentMinSize = Self.defaultContentMinSize
        window.contentMaxSize = Self.defaultContentMaxSize
        let targetFrame = expandedFrame ?? window.frame
        let constrainedFrame = window.constrainFrameRect(targetFrame, to: window.screen)
        window.setFrame(constrainedFrame, display: true)

        expandedFrame = nil
        isCompact = false
        saveWindowState()
    }

    /// Toggles every AppKit chrome affordance §3.4 lists, **including `.titled` itself**: a `.titled`
    /// window keeps an internal minimum-height reservation for its invisible title bar that
    /// `setFrame` can't shrink past (measured: pill landed at 50pt vs. the requested 44pt
    /// `compactPillSize`). `standardWindowButton(_:)` only resolves while `.titled` is present, so
    /// hide/show must bracket the styleMask toggle (before removing it, after restoring it).
    private func applyChrome(compact: Bool) {
        guard let window else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        if compact {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            for button in buttons { window.standardWindowButton(button)?.isHidden = true }
            window.isMovableByWindowBackground = true
            window.styleMask.remove([.resizable, .titled])
        } else {
            window.styleMask.insert([.titled, .resizable])
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            for button in buttons { window.standardWindowButton(button)?.isHidden = false }
            window.isMovableByWindowBackground = false
        }
    }

    // MARK: - NSWindowDelegate: position/size persistence (section 9)

    func windowDidMove(_ notification: Notification) {
        scheduleWindowStateSave()
    }

    func windowDidResize(_ notification: Notification) {
        scheduleWindowStateSave()
    }

    /// Debounces bursts of move/resize events (e.g. a drag generates many in quick succession)
    /// down to a single `AppState.upsertWindowState` write, matching Chirami's
    /// `NoteWindowController.saveWindowState()` call-frequency pattern
    /// (`docs/references/chirami-map.md` section 3).
    ///
    /// `docs/design/18-recording-window-stow-and-compact.md` §5.2/R5: guarded at the *scheduling*
    /// side so a move/resize while compact never even queues a save.
    private func scheduleWindowStateSave() {
        guard !isCompact else { return }
        moveResizeDebounceTask?.cancel()
        let debounceNanoseconds = moveResizeDebounceNanoseconds
        moveResizeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.saveWindowState()
        }
    }

    /// `docs/design/18-recording-window-stow-and-compact.md` §5.2/R5: guarded again here (not just
    /// in `scheduleWindowStateSave()`) so a save already scheduled *before* a compact transition
    /// began can't slip through and persist the pill frame once its debounce timer fires mid-transition.
    private func saveWindowState() {
        guard !isCompact, let window else { return }
        let frame = window.frame
        appState.upsertWindowState(
            WorkspaceWindowState(
                sessionId: sessionId,
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height,
                visible: window.isVisible,
                activeTab: viewModel.activeTab,
                meetingPaneMode: viewModel.meetingPaneMode
            )
        )
    }

    /// `docs/design/18-recording-window-stow-and-compact.md` §4.3's "visible = true" upsert, factored
    /// out of `saveWindowState()` so `unstow()` can call it even while `isCompact` is `true` (Minor-1
    /// fix -- see `unstow()`'s doc comment above for the gap this closes). Unlike
    /// `saveWindowState()`, this is **not** guarded on `!isCompact`: it always writes, but still
    /// upholds R5 by substituting `expandedFrame` (the pre-compact frame) for the window's *current*
    /// frame whenever compact, so the 380x44 pill frame itself is never the one persisted.
    /// `visible` is hardcoded `true` (not `window.isVisible`) since this only ever runs from
    /// `unstow()`, right after `showWindow(nil)` made the window visible.
    private func persistVisibleState() {
        guard let window else { return }
        let frame = isCompact ? (expandedFrame ?? window.frame) : window.frame
        appState.upsertWindowState(
            WorkspaceWindowState(
                sessionId: sessionId,
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height,
                visible: true,
                activeTab: viewModel.activeTab,
                meetingPaneMode: viewModel.meetingPaneMode
            )
        )
    }

    // MARK: - NSWindowDelegate: close notification (section 9)

    /// Reached only when the close was actually allowed through (`WindowCloseDecision.allowImmediately`
    /// or `.allowConsumingApproval`) — recording is guaranteed to already be stopped by this point,
    /// since `blocksWindowClose` is what gated the close in the first place.
    func windowWillClose(_ notification: Notification) {
        // Cancel any in-flight debounced save so a stale (e.g. `visible: true`) write can't race
        // past `WindowManager.workspaceWindowDidClose`'s `visible = false` update below.
        moveResizeDebounceTask?.cancel()
        moveResizeDebounceTask = nil

        // The one place web views are released (design 39 MD2): they are kept alive across every
        // tab and pane switch on purpose, so nothing shorter-lived may drop them.
        markdownWebViewStore.tearDown()

        WindowManager.shared.workspaceWindowDidClose(sessionId: sessionId)
    }
}

// `WindowCloseDecision` / `MeetingEndReshowDecision` live in `MeetingWorkspaceCloseDecision.swift`
// (same target, no import needed) -- moved out to keep this file under swiftlint's `file_length`
// limit now that `applyChrome(compact:)` also toggles `.titled`.
