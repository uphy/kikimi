import AppKit
import SwiftUI

// MARK: - PlainTextEditor

/// A minimal wrapper around a plain-text `NSTextView` (kikimi.md 10 章 "NSTextView（プレインテキスト）で
/// 実装（MVP 最小構成）"; `docs/design/06-ui-panels.md` section 2 diff table: "WKWebView は使わない" for
/// the Prep tab). Shared by the Prep tab's editors (`context.md` / `summary_template.md`, section
/// 6.2) rather than each owning a bespoke `NSViewRepresentable`.
///
/// `text` is updated on every keystroke so callers get live feedback (e.g. the Prep tab's byte-count
/// indicator, section 6.2's "18.2KB / 32KB" display). Persisting the edit is a separate concern: this
/// view debounces `textDidChange` by `debounceInterval` (default 500ms, section 6.2 "textDidChange を
/// デバウンス（例: 500ms）した上で saveContext(_:)/saveSummaryTemplate(_:) を呼ぶ") and only then invokes
/// `onDebouncedChange`, which callers wire to `MeetingWorkspaceViewModel.saveContext(_:)`/
/// `saveSummaryTemplate(_:)`. Keeping persistence behind an injected closure (rather than baking in a
/// specific view-model method) is what lets a single `PlainTextEditor` serve both editors.
///
/// A plain `View` (not itself an `NSViewRepresentable`) so it can layer a placeholder `Text` on top
/// of the actual `NSTextView` wrapper (`TextViewRepresentable` below) via `ZStack`
/// (`docs/design/17-session-window-redesign.md` §5.5) — `NSTextView` has no native placeholder API.
struct PlainTextEditor: View {
    @Binding var text: String

    /// `false` renders `text` as a read-only preview (`docs/design/05-watcher-runner.md` §10.3: a
    /// preset Watcher's edit sheet is "read-only プレビュー"), still selectable/copyable via
    /// `isSelectable`, just not editable. Every other caller (the Prep tab's `context.md`/
    /// `summary_template.md` editors, a session-local Watcher's edit sheet) leaves this at the
    /// default `true`.
    var isEditable: Bool = true

    /// Placeholder text shown (in `.secondaryLabelColor`) whenever `text` is empty
    /// (`docs/design/17-session-window-redesign.md` §5.2 B-1/§5.5). `nil` (the default) renders no
    /// placeholder at all, matching every pre-existing caller's behavior exactly.
    var placeholder: String?

    /// How long to wait after the last keystroke before firing `onDebouncedChange`.
    var debounceInterval: TimeInterval = 0.5

    /// Invoked on the main actor `debounceInterval` after the user stops typing, with the
    /// text as of that moment. Defaults to a no-op so call sites that only need the live
    /// `text` binding (no persistence) don't have to supply one.
    var onDebouncedChange: (String) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextViewRepresentable(
                text: $text,
                isEditable: isEditable,
                debounceInterval: debounceInterval,
                onDebouncedChange: onDebouncedChange
            )

            if let placeholder, text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.top, 8)
                    .padding(.leading, 11)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - TextViewRepresentable

/// The actual `NSTextView`/`NSScrollView` wrapper `PlainTextEditor` layers its placeholder on top of.
/// Split out of `PlainTextEditor` itself so that type can stay a plain `View` (needed for the
/// placeholder `ZStack`, see `PlainTextEditor`'s doc comment) while this nested representable keeps
/// every pre-existing behavior (live `text` binding, debounced persistence) unchanged. Internal (not
/// `private`) so `PlainTextEditorTests.swift` (`@testable import Kikimi`) can keep exercising
/// `Coordinator.textDidChange(_:)`/`deinit` directly, exactly as it did against
/// `PlainTextEditor.Coordinator` before this file split the representable out.
struct TextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var debounceInterval: TimeInterval
    var onDebouncedChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)

        // Let the text container track the scroll view's width and grow vertically only, so long
        // lines wrap instead of requiring horizontal scrolling (plain-text notes, not code).
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Refresh the coordinator's copy of `self` on every render, since `TextViewRepresentable` is a
        // value type and `onDebouncedChange`/`debounceInterval` may have been rebuilt with fresh
        // captures (e.g. a closure capturing an updated `sessionHandle`).
        context.coordinator.parent = self

        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable

        // Never mutate the text view's string while an IME composition is in flight (marked text —
        // Japanese/Chinese/Korean 変換中の未確定文字列). `textDidChange` fires for *every* intermediate
        // marked-text state and pushes it into the `text` binding, so a re-render can re-enter
        // `updateNSView` with a *stale* binding value while the text view already holds newer marked
        // text; assigning `textView.string` then tears down the live composition and drops the
        // half-typed characters — exactly the "素早く日本語を入力すると消える" symptom (and, for English,
        // why it never reproduced: ASCII input never goes through marked text). The binding reconciles
        // normally on the next `updateNSView` once composition commits, which fires a final
        // `textDidChange` with no marked text remaining.
        guard !textView.hasMarkedText() else { return }

        // Only push `text` into the `NSTextView` when it actually differs from what's already
        // displayed. Every keystroke round-trips through `Coordinator.textDidChange(_:)` → the
        // `text` binding's setter → SwiftUI re-invoking `updateNSView` with a `TextViewRepresentable`
        // whose `text` already equals `textView.string`; skipping the redundant `string` assignment
        // in that case avoids resetting the cursor position/selection while the user is typing.
        // When `text` genuinely changes out from under the view (initial load, "他セッションから複製…" —
        // section 6.2), this branch replaces the content as expected.
        if textView.string != text {
            textView.string = text
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextViewRepresentable
        private var pendingWorkItem: DispatchWorkItem?

        /// The most recent text that hasn't been flushed via `onDebouncedChange` yet. Mirrored here
        /// (rather than only inside `pendingWorkItem`'s closure) so `deinit` can flush it
        /// synchronously — a `[weak self]`-captured `DispatchWorkItem` becomes a no-op once `self`
        /// starts deallocating, so relying on the scheduled item alone would silently drop the last
        /// <`debounceInterval`> of edits whenever the view disappears (tab switch, window close)
        /// before the debounce timer fires.
        private var pendingText: String?

        init(_ parent: TextViewRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let updatedText = textView.string

            // Reflect every keystroke into the binding immediately, so anything observing `text`
            // (byte-count indicator, etc.) stays live even though persistence is debounced.
            parent.text = updatedText
            pendingText = updatedText

            pendingWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.pendingText = nil
                self?.parent.onDebouncedChange(updatedText)
            }
            pendingWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + parent.debounceInterval, execute: workItem)
        }

        deinit {
            pendingWorkItem?.cancel()
            // Flush any edit that hasn't made it through the debounce timer yet, so a rapid
            // type-then-close/switch-tab doesn't silently lose the last edit.
            if let pendingText {
                parent.onDebouncedChange(pendingText)
            }
        }
    }
}
