import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `MarkdownWebViewAssets` (`docs/design/39-webview-markdown.md` §8.1).
///
/// The case that matters is the missing one: a developer who runs `swift build` without
/// `mise run build:web` has no bundle, and the view must fall back to plain text (MD15) rather
/// than showing an empty rectangle or crashing.
@Suite("MarkdownWebViewAssets")
struct MarkdownWebViewAssetsTests {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "kikimi-assets-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("a directory containing index.html resolves")
    func present() throws {
        let resources = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: resources) }

        let editor = resources.appending(path: "editor", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: editor, withIntermediateDirectories: true)
        try "<html></html>".write(to: editor.appending(path: "index.html"), atomically: true, encoding: .utf8)

        #expect(MarkdownWebViewAssets.directory(named: "editor", in: resources) == editor)
    }

    @Test("a missing directory resolves to nil")
    func missingDirectory() throws {
        let resources = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: resources) }

        #expect(MarkdownWebViewAssets.directory(named: "editor", in: resources) == nil)
    }

    @Test("a directory without index.html resolves to nil (an interrupted or partial build)")
    func directoryWithoutIndex() throws {
        let resources = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: resources) }

        let editor = resources.appending(path: "editor", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: editor, withIntermediateDirectories: true)
        try "".write(to: editor.appending(path: "bundle.js"), atomically: true, encoding: .utf8)

        #expect(MarkdownWebViewAssets.directory(named: "editor", in: resources) == nil)
    }

    @Test("a nil resource URL resolves to nil rather than trapping")
    func nilResourceURL() {
        #expect(MarkdownWebViewAssets.directory(named: "editor", in: nil) == nil)
    }
}
