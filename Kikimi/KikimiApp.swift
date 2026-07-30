import AppKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "KikimiApp")

@main
struct KikimiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuView(menuModel: WindowManager.shared.menuBarMenu)
        } label: {
            MenuBarLabelView(statusModel: WindowManager.shared.menuBarStatus)
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - MenuBarLabelView

/// `docs/design/18-recording-window-stow-and-compact.md` §3.3/§5.3: the `MenuBarExtra` label,
/// driven entirely by `WindowManager.shared.menuBarStatus` (in turn derived by
/// `MenuBarStatus.derive`, `Kikimi/Window/MenuBarStatus.swift`) -- this view itself makes no
/// decisions, only renders whatever `status` already resolved to.
struct MenuBarLabelView: View {
    @ObservedObject var statusModel: MenuBarStatusModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            if let timerText = statusModel.status.timerText {
                Text(timerText).monospacedDigit()
            }
        }
    }

    private var iconName: String {
        switch statusModel.status.icon {
        case .idle: return "waveform"
        case .recording: return "record.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - MenuBarMenuView

/// §3.3's menu body: an optional disabled "録音中: <title>" info row plus a Recording-only
/// "会議を終了…" item (confirmed via `WindowManager.endRecordingMeetingFromMenuBar()`), one "<title>
/// を表示" row per stowed session (§3.2's re-display route), then the pre-existing "新規セッション"/
/// "セッション一覧"/"設定"/"終了" items, unchanged.
///
/// Observes `MenuBarMenuModel`, **not** `MenuBarStatusModel` (§3.3/§4.2/§6 failure mode #15):
/// `MenuBarExtra(.menu)`'s content is re-evaluated live while the menu is open, and any such
/// re-evaluation rebuilds the backing `NSMenu`'s items, resetting the user's current hover
/// highlight back to the first row. `MenuBarStatusModel.status` changes every second while
/// Recording (the elapsed-time label), so this view must never touch it -- `MenuBarMenuModel`
/// carries a `timerText`-free projection that only republishes when it actually changes, which is
/// why the info row below shows no elapsed time (the live count is `MenuBarLabelView`'s job, right
/// next to it in the menu bar).
struct MenuBarMenuView: View {
    @ObservedObject var menuModel: MenuBarMenuModel

    var body: some View {
        Group {
            if let recordingTitle = menuModel.content.recordingTitle {
                Text("録音中: \(recordingTitle)")
                // §3.3: the only Recording-only confirmed path to on_session_end reachable without
                // the window's own context; `endRecordingMeetingFromMenuBar()` shows the confirmation
                // alert itself.
                Button("会議を終了…") {
                    WindowManager.shared.endRecordingMeetingFromMenuBar()
                }
            }

            ForEach(menuModel.content.hiddenWindows) { item in
                Button("\(item.title) を表示") {
                    WindowManager.shared.showWorkspaceWindow(sessionId: item.id)
                }
            }

            if menuModel.content.recordingTitle != nil || !menuModel.content.hiddenWindows.isEmpty {
                Divider()
            }

            Button("新規セッション") {
                Task { @MainActor in
                    do {
                        try await WindowManager.shared.createDraftWorkspace()
                    } catch {
                        logger.error("Failed to create draft workspace from menu bar: \(error, privacy: .public)")
                    }
                }
            }
            Button("セッション一覧") {
                WindowManager.shared.showSessionList()
            }
            Button("ディクテーション履歴") {
                WindowManager.shared.showDictationHistory()
            }
            Button("用語を登録…") {
                WindowManager.shared.showGlossaryQuickAdd()
            }
            Button("設定") {
                WindowManager.shared.showSettings()
            }
            Divider()
            Button("終了") {
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - AppDelegate

/// See `docs/design/06-ui-panels.md` section 9 ("フローティング挙動・起動時の復元") for the full
/// rationale behind the `applicationShouldTerminate`/`terminateLater` sequence below.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Registers the `kAEGetURL` Apple Event handler (`docs/design/09-raycast-integration.md`
    /// section 2). Done in `init()`, not `applicationWillFinishLaunching`/`applicationDidFinishLaunching`,
    /// so the handler is in place before any Apple Event delivered during launch could be missed —
    /// mirrors the reference pattern in Chirami's `ChiramiApp.swift` (local-only reference repo).
    override init() {
        super.init()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await WindowManager.shared.launch()
        }
        DictationController.shared.launch()
    }

    // MARK: kikimi:// URL scheme (docs/design/09-raycast-integration.md)

    /// Primary receive path: `open "kikimi://..."`, Dock icon URL drops, etc.
    func application(_ application: NSApplication, open urls: [URL]) {
        routeIncomingURLs(urls)
    }

    /// Fallback receive path (section 2): older `open location`/AppleScript-style delivery that
    /// does not always reach `application(_:open:)`.
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            logger.error("Failed to decode kAEGetURL Apple Event")
            return
        }
        routeIncomingURLs([url])
    }

    /// Shared entry point for both receive paths above (section 2: "両経路とも最終的に同じ
    /// `routeIncomingURLs` に委譲し、二重実装を避ける").
    private func routeIncomingURLs(_ urls: [URL]) {
        for url in urls {
            guard let route = KikimiURLRoute.parse(url) else {
                logger.warning("Ignoring unrecognized URL: \(url.absoluteString, privacy: .public)")
                continue
            }
            Task { @MainActor in
                await self.handle(route)
            }
        }
    }

    /// Routes a parsed `KikimiURLRoute` to the `WindowManager` entry point it names (section 1's
    /// table, 06-ui-panels.md section 5.2). Failures are logged only: there is no UI surface to
    /// present a dialog to for a non-interactive Raycast-triggered call (section 4).
    private func handle(_ route: KikimiURLRoute) async {
        switch route {
        case .newWindow(let basedOn):
            do {
                try await WindowManager.shared.createDraftWorkspace(basedOn: basedOn)
            } catch {
                logger.warning("kikimi://window/new failed: \(error.localizedDescription, privacy: .public)")
            }
        case .recordQuick:
            do {
                try await WindowManager.shared.quickRecord()
            } catch SessionStoreError.anotherSessionRecording {
                // Already logged as `.warning` by `WindowManager.quickRecord()` itself (section 4);
                // this is purely the non-intrusive user-facing feedback (no NSAlert: this is a
                // menu-bar app and the call is non-interactive).
                NSSound.beep()
            } catch {
                logger.error("kikimi://record/quick failed: \(error.localizedDescription, privacy: .public)")
            }
        case .debugWebView(let target, let action):
            await handleDebugWebView(target: target, action: action)
        }
    }

    /// `kikimi://debug/webview` (`docs/design/39-webview-markdown.md` MD12 / §8.3): lets
    /// `kikimi-verify` read and click inside a WebView-rendered surface from outside the process.
    ///
    /// Everything is reported through the log rather than a dialog, matching the rest of the URL
    /// scheme's non-interactive contract. `out` exists because a script wants a file it can diff, not
    /// a line it has to scrape out of `log stream`.
    private func handleDebugWebView(
        target: KikimiURLRoute.DebugWebViewTarget,
        action: KikimiURLRoute.DebugWebViewAction
    ) async {
        guard DebugBridgeMode.isActive else {
            // Not an error: a stray URL in a normal session should be inert, and saying why makes
            // that obvious to whoever fired it.
            logger.warning("kikimi://debug/webview ignored: set KIKIMI_DEBUG_BRIDGE=1 (or run under KIKIMI_TEST_HIDDEN / KIKIMI_STUB_LLM)")
            return
        }
        guard let host = WindowManager.shared.debugWebViewHost(target: target) else {
            logger.error("kikimi://debug/webview: no web view for target \(target.rawValue, privacy: .public)")
            return
        }

        switch action {
        case .dump(let out):
            guard let text = await host.dumpText() else {
                logger.error("kikimi://debug/webview: dump failed for \(target.rawValue, privacy: .public)")
                return
            }
            guard let out else {
                logger.info("webview dump [\(target.rawValue, privacy: .public)]: \(text, privacy: .public)")
                return
            }
            do {
                try text.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
                logger.info("webview dump [\(target.rawValue, privacy: .public)] -> \(out, privacy: .public) (\(text.count) chars)")
            } catch {
                logger.error("kikimi://debug/webview: writing \(out, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        case .click(let testId, let out):
            let clicked = await host.clickTestId(testId)
            if clicked {
                logger.info("webview click [\(target.rawValue, privacy: .public)]: \(testId, privacy: .public)")
            } else {
                logger.error("kikimi://debug/webview: no element with data-testid=\(testId, privacy: .public) in \(target.rawValue, privacy: .public)")
            }
            guard let out else { return }
            do {
                try (clicked ? "clicked" : "not-found").write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
            } catch {
                logger.error("kikimi://debug/webview: writing \(out, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Implements the `terminateLater` pattern (06-ui-panels.md section 9) so that Recording ->
    /// stop and the final `SessionHandle.flush()` of every open window can be awaited before the
    /// process actually exits. `applicationWillTerminate` is intentionally not used: it is a
    /// synchronous callback and cannot await the async cleanup this sequence depends on.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Only prompt for confirmation while a recording is in progress. `NSAlert.runModal()` is
        // itself a synchronous API, so it is safe to call here before any `Task` is spawned.
        if WindowManager.shared.recordingSessionId != nil {
            let alert = NSAlert()
            alert.messageText = "録音中です"
            alert.informativeText = "会議の録音を停止してからアプリを終了します。よろしいですか？"
            alert.addButton(withTitle: "終了する")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return .terminateCancel
            }
        }

        Task { @MainActor in
            // `WindowManager.prepareForTermination()` awaits `stopRecording()` (if a session is
            // recording) and then flushes every open window's `SessionHandle`. Race it against a
            // 5-second timeout so a hang in flush()/stopRecording() can never leave the app unable
            // to quit (06-ui-panels.md section 9, failure mode #15): data may not be fully
            // finalized in that case, but that is preferable to an unkillable app.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await WindowManager.shared.prepareForTermination() }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
