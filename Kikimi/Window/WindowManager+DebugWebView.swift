import AppKit
import Foundation

// MARK: - WindowManager + debug web view bridge

/// The `kikimi://debug/webview` lookup (`docs/design/39-webview-markdown.md` MD12). Its own file for
/// `file_length`, the same split `WindowManager+Control.swift` / `WindowManager+Profiles.swift` made.
extension WindowManager {
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
        case .summaryTopics: slot = .summaryTopics
        case .watchers: slot = .watchers
        case .chat: slot = .chat
        case .diagram: return nil
        }

        let controller = workspaceControllers.values.first { $0.window?.isKeyWindow == true }
            ?? workspaceControllers.values.first
        return controller?.markdownWebViewStore.existingHost(for: slot)
    }
}
