import Foundation
import OSLog

// MARK: - MarkdownWebViewAssets

/// Locates the bundled web assets that back every Markdown view
/// (`docs/design/39-webview-markdown.md` §3.2/§7).
///
/// The assets are copied into `Kikimi.app/Contents/Resources/<directory>/` by
/// `.mise/tasks/build/_default`, the same way `AppIcon.icns` and the menu bar icons are — Kikimi
/// does not use SPM's resource bundles (`Package.swift` `exclude`s its `Resources/` subtrees), so
/// `Bundle.main.resourceURL` is the only lookup that works for both `mise run build` output and an
/// installed `~/Applications/Kikimi.app`.
///
/// Returning `nil` is a supported outcome, not a crash: a developer running `swift build` without
/// having run `mise run build:web` has no `bundle.js`, and callers fall back to plain text with an
/// on-screen notice (design 39 MD15).
enum MarkdownWebViewAssets {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "MarkdownWebView")

    /// The directory holding `index.html`, or `nil` when the assets are missing.
    ///
    /// `fileManager` is injectable purely so `MarkdownWebViewAssetsTests` can exercise the missing
    /// case without touching the real bundle.
    static func directory(named name: String, in resourceURL: URL?, fileManager: FileManager = .default) -> URL? {
        guard let resourceURL else { return nil }
        let directory = resourceURL.appending(path: name, directoryHint: .isDirectory)
        let indexHTML = directory.appending(path: "index.html", directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: indexHTML.path(percentEncoded: false)) else { return nil }
        return directory
    }

    /// `directory(named:in:fileManager:)` against the running app's bundle, logging the miss once at
    /// the call site that needs it.
    static func mainBundleDirectory(named name: String) -> URL? {
        guard let directory = directory(named: name, in: Bundle.main.resourceURL) else {
            logger.error("Web assets missing: Resources/\(name, privacy: .public)/index.html not found. Run `mise run build`.")
            return nil
        }
        return directory
    }
}
