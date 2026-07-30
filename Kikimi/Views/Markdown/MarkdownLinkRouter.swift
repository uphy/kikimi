import Foundation

// MARK: - MarkdownLinkRouter

/// Decides what a link clicked inside a Markdown web view means
/// (`docs/design/39-webview-markdown.md` MD6 / §3.3).
///
/// Pure and side-effect-free so it is directly unit-testable, the same shape `KikimiURLRoute` takes:
/// the caller (`MarkdownWebViewHost`) is responsible for actually jumping to a segment, opening a
/// browser, or logging the miss.
///
/// The page never navigates on its own — `document.ts` calls `preventDefault()` on every anchor and
/// reports the href here instead, and `decidePolicyFor` cancels anything that slips past. So this
/// is a classifier, not a gate: an unrecognized scheme costs nothing but a log line.
enum MarkdownLinkRouter {
    enum Destination: Equatable {
        /// `kikimi-seg:seg_00042`, produced by `WatcherViewRenderer.linkifySegmentIds`
        /// (`docs/design/05-watcher-runner.md` §8.1). The payload is the bare seg id.
        case segment(String)
        /// `http:` / `https:`, handed to `NSWorkspace`.
        case external(URL)
        /// Anything else: `javascript:`, `file:`, relative paths, empty strings.
        case ignored
    }

    static func route(_ raw: String) -> Destination {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }

        // Parsed by prefix rather than by `URL.scheme`: `kikimi-seg:seg_00042` has no authority
        // component, and `URL` is inconsistent about such opaque URLs across macOS versions.
        let segmentPrefix = "kikimi-seg:"
        if trimmed.hasPrefix(segmentPrefix) {
            let id = String(trimmed.dropFirst(segmentPrefix.count))
            return id.isEmpty ? .ignored : .segment(id)
        }

        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return .ignored }
        guard scheme == "http" || scheme == "https" else { return .ignored }
        return .external(url)
    }
}
