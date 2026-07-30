import AppKit
import Combine
import OSLog
import WebKit

// MARK: - MarkdownWebViewHost

/// One `WKWebView` and everything that keeps it usable: the JS bridge, the pre-`ready` queue, theme
/// injection, and the fallbacks (`docs/design/39-webview-markdown.md` §3.2 / §7).
///
/// Owned by `MarkdownWebViewStore`, never by a SwiftUI view — MD2. Phase A0 measured that a plain
/// tab switch tears the representable down, so a host created inside `makeNSView` would reload the
/// 312KB bundle every time the user leaves and returns to the tab, losing the scroll position with
/// it.
@MainActor
final class MarkdownWebViewHost: NSObject, ObservableObject {
    /// Whether the page can be shown at all. `.failed` drives the plain-text fallback (MD15).
    enum State: Equatable {
        case loading
        case ready
        case failed(reason: String)
    }

    @Published private(set) var state: State = .loading

    /// `kikimi-seg:` link (design 05 §8.1). Replaced on every SwiftUI update so the closure always
    /// captures a live view model.
    var onOpenSegment: (String) -> Void = { _ in }
    /// Phase C (§3.6); wired here so the bridge does not need a second pass later.
    var onCopyTurn: (String) -> Void = { _ in }
    var onRetryTurn: (String) -> Void = { _ in }
    /// The zoom button on a diagram (`docs/design/40-diagram-zoom.md` §3.2). Defaulted rather than
    /// threaded through every tab view: the destination is the same single overlay window regardless
    /// of which surface the diagram was in, and the anchor (which screen to open on, DZ2) is
    /// something only this object knows.
    lazy var onZoomDiagram: (String) -> Void = { [weak self] source in
        WindowManager.shared.showDiagramZoom(source: source, anchoredTo: self?.webView?.window)
    }
    /// Escape / ⌘W / a click outside the diagram, from the overlay's own page (DZ8). Only the overlay
    /// window sets this.
    var onCloseDiagram: () -> Void = {}

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "MarkdownWebView")
    /// How long the page gets to call `ready` before the fallback takes over (§7). Generous enough
    /// for a cold WebKit process; a late `ready` still recovers.
    private static let readyTimeout = Duration.seconds(3)

    private(set) var webView: FirstMouseWKWebView?
    private var assetsDirectory: URL?
    /// Calls made before `ready`, replayed in order once it arrives (MD11). The opening
    /// `setContent` routinely beats the page: the summary is already on disk when the window opens.
    private var pendingCalls: [(function: String, payload: [String: Any])] = []
    private var isReady = false
    /// Last content pushed, so an unchanged SwiftUI update is not re-rendered, and so a recovered
    /// web content process can be restored to what it was showing.
    private var lastContent: (markdown: String, docKey: String)?
    /// Chat's equivalents, for the same "don't re-push what the page already has" reason.
    private var lastTurns: [ChatTurnView]?
    private var lastResponding: (responding: Bool, since: Double?)?
    private var lastCopyFeedbackTurnId: String?
    private var hasRecoveredFromCrash = false

    // MARK: Lifecycle

    /// Builds the web view, or fails into `.failed` when the bundle is missing (a `swift build`
    /// without `mise run build:web`).
    func start() {
        guard webView == nil, case .loading = state else { return }
        guard let assetsDirectory = MarkdownWebViewAssets.mainBundleDirectory(named: "editor") else {
            state = .failed(reason: "web assets missing")
            return
        }
        self.assetsDirectory = assetsDirectory

        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(MarkdownWebViewMessageProxy(host: self), name: "kikimi")
        configuration.userContentController = controller

        let webView = FirstMouseWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        // Let the panel's own material show through, the way `Theme.summary` did by dropping
        // GitHub's opaque background.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.onAppearanceChange = { [weak self] in self?.handleAppearanceChange() }
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.webView = webView

        load()
    }

    private func load() {
        guard let webView, let assetsDirectory else { return }
        isReady = false
        let indexHTML = assetsDirectory.appending(path: "index.html", directoryHint: .notDirectory)
        webView.loadFileURL(indexHTML, allowingReadAccessTo: assetsDirectory)

        Task { [weak self] in
            try? await Task.sleep(for: Self.readyTimeout)
            guard let self, !self.isReady else { return }
            Self.logger.error("Markdown web view did not become ready within 3s; falling back to plain text")
            self.state = .failed(reason: "page did not load")
        }
    }

    // MARK: Content

    /// design 39 MD8. `docKey` tells the page whether this is an update of what it already shows
    /// (keep the scroll position) or a different document (start at the top).
    func setContent(markdown: String, docKey: String) {
        guard lastContent?.markdown != markdown || lastContent?.docKey != docKey else { return }
        lastContent = (markdown, docKey)
        call("setContent", payload: ["markdown": markdown, "docKey": docKey])
    }

    // MARK: Chat (§3.6)

    /// The whole folded history, replaced as a unit. Cheap enough at the sizes `chat.jsonl` reaches,
    /// and it keeps the page from having to reconcile insertions itself.
    func setTurns(_ turns: [ChatTurnView]) {
        guard lastTurns != turns else { return }
        lastTurns = turns
        call("setTurns", payload: ["turns": turns.map(\.payload)])
    }

    /// Drives the spinner and its elapsed-seconds counter. `since` is what the page counts from, so
    /// a tab switch mid-answer resumes the count instead of restarting it.
    func setResponding(_ responding: Bool, since: Date?) {
        let sinceEpoch = since?.timeIntervalSince1970
        guard lastResponding?.responding != responding || lastResponding?.since != sinceEpoch else { return }
        lastResponding = (responding, sinceEpoch)
        call("setResponding", payload: ["responding": responding, "since": sinceEpoch ?? NSNull()])
    }

    /// The copy checkmark. Driven from Swift rather than from the click so that a *failed* pasteboard
    /// write shows nothing (design 37 §6 / §7's test item (f)).
    func setCopyFeedback(turnId: String?) {
        guard lastCopyFeedbackTurnId != turnId else { return }
        lastCopyFeedbackTurnId = turnId
        call("setCopyFeedback", payload: ["turnId": turnId ?? NSNull()])
    }

    // MARK: Diagram overlay (design 40)

    /// Boots the overlay page with one diagram. Only ever called on the overlay window's host.
    func setDiagram(source: String) {
        // No "same as last time" guard: reopening the overlay on the same diagram must redraw it,
        // since the previous run left it panned and zoomed wherever the reader stopped.
        call("setDiagram", payload: ["source": source])
    }

    private func pushTheme() {
        guard let webView else { return }
        call("setTheme", payload: ["vars": MarkdownWebViewTheme.cssVariables(for: webView.effectiveAppearance)])
    }

    /// Light <-> dark. Text and code recolor from the CSS variables alone, but a mermaid diagram
    /// bakes its palette in at render time (§3.4), so the document is rendered again — same
    /// `docKey`, so the reader keeps their scroll position.
    private func handleAppearanceChange() {
        pushTheme()
        guard let lastContent else { return }
        call("setContent", payload: ["markdown": lastContent.markdown, "docKey": lastContent.docKey])
    }

    /// MD11: values are passed as arguments, never interpolated into a script string. Meeting text
    /// contains quotes, newlines, and the occasional U+2028 — string building would break on the
    /// first summary.
    ///
    /// Every page function takes **one object**, always named `payload`. `callAsyncJavaScript` hands
    /// arguments over as a dictionary while the script has to name them positionally, so a
    /// multi-parameter signature would require Swift and `bridge.ts` to agree on an order that
    /// nothing verifies — and they did not: `setContent`'s two arguments were being passed swapped
    /// (the dictionary's keys were sorted, putting `docKey` first), so the document key was rendered
    /// as the body text. With a single object there is no order to get wrong.
    private func call(_ function: String, payload: [String: Any]) {
        guard isReady else {
            pendingCalls.append((function, payload))
            return
        }
        guard let webView else { return }
        Task {
            do {
                _ = try await webView.callAsyncJavaScript(
                    "window.kikimi.\(function)(payload);",
                    arguments: ["payload": payload],
                    contentWorld: .page
                )
            } catch {
                Self.logger.error("\(function, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func flushPendingCalls() {
        let queued = pendingCalls
        pendingCalls = []
        // Theme first so nothing is ever painted with default colors and then recolored.
        pushTheme()
        for call in queued where call.function != "setTheme" {
            self.call(call.function, payload: call.payload)
        }
    }

    // MARK: Bridge

    fileprivate func handle(message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            isReady = true
            state = .ready
            flushPendingCalls()
        case "rendered":
            break
        case "openLink":
            handleLink(message["url"] as? String ?? "")
        case "copyTurn":
            if let id = message["id"] as? String { onCopyTurn(id) }
        case "retryTurn":
            if let id = message["id"] as? String { onRetryTurn(id) }
        case "zoomDiagram":
            if let source = message["source"] as? String { onZoomDiagram(source) }
        case "closeDiagram":
            onCloseDiagram()
        case "log":
            logFromPage(message)
        default:
            Self.logger.debug("unknown bridge message: \(String(describing: message["type"]), privacy: .public)")
        }
    }

    private func handleLink(_ raw: String) {
        switch MarkdownLinkRouter.route(raw) {
        case .segment(let id):
            onOpenSegment(id)
        case .external(let url):
            NSWorkspace.shared.open(url)
        case .ignored:
            Self.logger.info("ignored link: \(raw, privacy: .public)")
        }
    }

    private func logFromPage(_ message: [String: Any]) {
        let text = message["message"] as? String ?? ""
        switch message["level"] as? String {
        case "error":
            Self.logger.error("page: \(text, privacy: .public)")
        case "warn":
            Self.logger.warning("page: \(text, privacy: .public)")
        default:
            Self.logger.debug("page: \(text, privacy: .public)")
        }
    }

    // MARK: Verification hooks (MD12)

    /// Returns the page's rendered text. Reached only through `kikimi://debug/webview`, which
    /// `DebugBridgeMode` gates on a test environment (MD12).
    func dumpText() async -> String? {
        guard let webView, isReady else {
            Self.logger.warning("dumpText: web view not ready (state: \(String(describing: self.state), privacy: .public))")
            return nil
        }
        let result = try? await webView.callAsyncJavaScript(
            "return window.__kikimiDumpText ? window.__kikimiDumpText() : null;",
            contentWorld: .page
        )
        return result as? String
    }

    /// Clicks the element carrying `data-testid`, returning whether it was found. The operational
    /// half of MD12: an AX-driven click cannot address elements inside a web view, and the copy /
    /// retry / zoom buttons all live there now.
    func clickTestId(_ testId: String) async -> Bool {
        guard let webView, isReady else {
            Self.logger.warning("clickTestId: web view not ready")
            return false
        }
        let result = try? await webView.callAsyncJavaScript(
            "return window.__kikimiClick ? window.__kikimiClick(testId) : false;",
            arguments: ["testId": testId],
            contentWorld: .page
        )
        return (result as? Bool) ?? false
    }
}

// MARK: - WKNavigationDelegate

extension MarkdownWebViewHost: WKNavigationDelegate {
    /// MD6: only the bundled assets may load. Cancelling *everything* would also cancel
    /// `loadFileURL`'s own navigation and leave a blank page, so the assets directory is allowed and
    /// nothing else is. Links never get here in practice — `document.ts` calls `preventDefault()`
    /// and reports them over the bridge — this is the second line of defense.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        Task { @MainActor in
            guard let url, url.isFileURL, let assetsDirectory = self.assetsDirectory,
                  url.path(percentEncoded: false).hasPrefix(assetsDirectory.path(percentEncoded: false)) else {
                if let url { Self.logger.info("cancelled navigation to \(url.absoluteString, privacy: .public)") }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let description = error.localizedDescription
        Task { @MainActor in
            Self.logger.error("navigation failed: \(description, privacy: .public)")
            self.state = .failed(reason: description)
        }
    }

    /// §7: recover once. A web content process that dies twice is not going to serve this session,
    /// and retrying forever would hide the problem behind an empty view.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            guard !self.hasRecoveredFromCrash else {
                Self.logger.error("web content process terminated again; falling back to plain text")
                self.state = .failed(reason: "web content process terminated")
                return
            }
            self.hasRecoveredFromCrash = true
            Self.logger.warning("web content process terminated; reloading once")
            // Whatever the page was showing has to be pushed again after the reload, so the
            // "already sent this" guards are cleared first.
            let content = self.lastContent
            let turns = self.lastTurns
            let responding = self.lastResponding
            self.lastContent = nil
            self.lastTurns = nil
            self.lastResponding = nil
            self.lastCopyFeedbackTurnId = nil
            self.load()
            if let content { self.setContent(markdown: content.markdown, docKey: content.docKey) }
            if let turns { self.setTurns(turns) }
            if let responding {
                self.setResponding(responding.responding, since: responding.since.map { Date(timeIntervalSince1970: $0) })
            }
        }
    }
}

// MARK: - MarkdownWebViewMessageProxy

/// Holds the host weakly: `WKUserContentController` retains its handlers, and the host owns the web
/// view that owns the controller.
private final class MarkdownWebViewMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var host: MarkdownWebViewHost?

    init(host: MarkdownWebViewHost) {
        self.host = host
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor [weak host] in
            host?.handle(message: body)
        }
    }
}
