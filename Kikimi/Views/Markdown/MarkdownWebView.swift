import AppKit
import SwiftUI
import WebKit

// MARK: - MarkdownWebView

/// Renders a Markdown document (`docs/design/39-webview-markdown.md` §3.5). The Summary and
/// Watchers tabs' one renderer; chat follows in Phase C.
///
/// The web view itself lives in `MarkdownWebViewStore`, not here (MD2) — this view only hands it a
/// place to sit and pushes content into it. When the page is unusable (missing bundle, dead content
/// process, no `ready`), it renders the Markdown as plain text with a notice instead (MD15).
struct MarkdownWebView: View {
    @ObservedObject var host: MarkdownWebViewHost

    let markdown: String
    /// Identifies the *document* (MD8): `"summary"`, `"watcher:<id>"`. Same key on an update means
    /// the reader keeps their scroll position; a different key starts at the top.
    let docKey: String
    var onOpenSegment: (String) -> Void = { _ in }

    var body: some View {
        Group {
            if case .failed(let reason) = host.state {
                MarkdownPlainTextFallback(markdown: markdown, reason: reason)
            } else {
                MarkdownWebViewRepresentable(host: host) { host in
                    // Refreshed on every update so the closure never captures a stale view model.
                    host.onOpenSegment = onOpenSegment
                    host.setContent(markdown: markdown, docKey: docKey)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - MarkdownWebViewRepresentable

/// Parks the store's web view inside SwiftUI's view tree. Deliberately trivial: everything with
/// state lives on `MarkdownWebViewHost`, because this type is created and destroyed at SwiftUI's
/// discretion (measured in Phase A0: a tab switch does exactly that).
///
/// `apply` is what the document and chat surfaces differ by — the parking is identical.
struct MarkdownWebViewRepresentable: NSViewRepresentable {
    let host: MarkdownWebViewHost
    let apply: (MarkdownWebViewHost) -> Void

    func makeNSView(context: Context) -> MarkdownWebViewContainer {
        MarkdownWebViewContainer()
    }

    func updateNSView(_ container: MarkdownWebViewContainer, context: Context) {
        // Re-attaching is idempotent, and it has to happen here rather than in `makeNSView`: the
        // host may still have been loading when the container was created.
        if let webView = host.webView {
            container.attach(webView)
        }
        apply(host)
    }

    static func dismantleNSView(_ container: MarkdownWebViewContainer, coordinator: ()) {
        // Detach only. The web view belongs to the store and outlives this view (MD2).
        container.detach()
    }
}

// MARK: - MarkdownWebViewContainer

/// A plain `NSView` whose only job is to hold whichever web view the store hands it, so the same
/// `WKWebView` can move between SwiftUI subtrees (pane switches move the Summary view between three
/// different positions in `MeetingTabView`).
final class MarkdownWebViewContainer: NSView {
    private weak var attached: NSView?

    func attach(_ webView: NSView) {
        // `superview !== self` matters as much as the identity check: a container that lost the web
        // view to a sibling (see `detach`) still remembers it, and must be able to take it back.
        guard attached !== webView || webView.superview !== self else { return }
        detach()
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        attached = webView
    }

    /// Only removes the web view if it is *still ours*. On a pane switch SwiftUI creates the new
    /// representable and lets it `attach` before dismantling the old one, so by the time this runs
    /// the web view is usually already a subview of the incoming container — an unconditional
    /// `removeFromSuperview()` would rip it back out and leave the new pane blank (the "サマリのみ" pane
    /// rendered white until the user went via 書き起こしのみ and back).
    func detach() {
        if attached?.superview === self {
            attached?.removeFromSuperview()
        }
        attached = nil
    }
}

// MARK: - MarkdownPlainTextFallback

/// design 39 MD15. Two things matter here: the content must still be readable, and the reader must
/// know this is not how it is supposed to look. A bare monospaced dump of `|---|` table syntax with
/// no explanation reads as a formatting bug — to users during a meeting, and to developers who ran
/// `swift build` without `mise run build:web`.
private struct MarkdownPlainTextFallback: View {
    let markdown: String
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("表示コンポーネントを読み込めませんでした。本文をそのまま表示しています。", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .help(reason)

            Divider()

            ScrollView {
                Text(markdown)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}
