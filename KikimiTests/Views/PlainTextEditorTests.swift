import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Kikimi

// MARK: - TextViewRepresentable.Coordinator

/// Unit tests for `TextViewRepresentable.Coordinator` (`Kikimi/Views/PlainTextEditor.swift`),
/// exercised directly via `NSTextViewDelegate.textDidChange(_:)` rather than through SwiftUI's
/// `makeNSView`/`updateNSView` (which need an opaque `Context` this test target can't construct).
/// Covers the debounce behavior described in the type's doc comment: live binding updates on every
/// keystroke, a single coalesced `onDebouncedChange` call after `debounceInterval`, and the
/// `deinit` flush that prevents a rapid type-then-close from silently dropping the last edit.
///
/// Targets `TextViewRepresentable` (not `PlainTextEditor` itself) since
/// `docs/design/17-session-window-redesign.md` §5.5 turned `PlainTextEditor` into a plain `View`
/// (a `ZStack` layering a placeholder `Text` over this representable) so it could show a
/// placeholder — the `NSViewRepresentable`/`Coordinator` surface this suite drives moved to
/// `TextViewRepresentable` accordingly.
@Suite("TextViewRepresentable.Coordinator")
@MainActor
struct PlainTextEditorCoordinatorTests {
    private func makeEditor(
        text: Binding<String>,
        debounceInterval: TimeInterval,
        onDebouncedChange: @escaping (String) -> Void = { _ in }
    ) -> TextViewRepresentable {
        TextViewRepresentable(text: text, isEditable: true, debounceInterval: debounceInterval, onDebouncedChange: onDebouncedChange)
    }

    private func fire(_ coordinator: TextViewRepresentable.Coordinator, text: String) {
        let textView = NSTextView()
        textView.string = text
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    @Test("textDidChange updates the text binding immediately, independent of the debounce timer")
    func textDidChangeUpdatesBindingImmediately() {
        var storedText = ""
        let binding = Binding(get: { storedText }, set: { storedText = $0 })
        // A debounce long enough that it can never fire during this synchronous test.
        let editor = makeEditor(text: binding, debounceInterval: 10)
        let coordinator = editor.makeCoordinator()

        fire(coordinator, text: "hello")

        #expect(storedText == "hello")
    }

    @Test("onDebouncedChange fires once, after debounceInterval, with the latest text")
    func onDebouncedChangeFiresAfterInterval() async {
        var storedText = ""
        let binding = Binding(get: { storedText }, set: { storedText = $0 })
        var received: [String] = []
        let editor = makeEditor(text: binding, debounceInterval: 0.02, onDebouncedChange: { received.append($0) })
        let coordinator = editor.makeCoordinator()

        fire(coordinator, text: "a")
        fire(coordinator, text: "ab")

        try? await Task.sleep(nanoseconds: 150_000_000) // well past the 20ms debounce

        #expect(received == ["ab"])
    }

    @Test("rapid successive keystrokes coalesce into a single onDebouncedChange call, not one per keystroke")
    func rapidKeystrokesCoalesce() async {
        var storedText = ""
        let binding = Binding(get: { storedText }, set: { storedText = $0 })
        var received: [String] = []
        let editor = makeEditor(text: binding, debounceInterval: 0.05, onDebouncedChange: { received.append($0) })
        let coordinator = editor.makeCoordinator()

        // Fire all four keystrokes back-to-back with no `await` in between, so this loop runs as one
        // uninterrupted synchronous stretch on the main actor. That's what actually guarantees
        // coalescing: each `fire()` cancels the previous `DispatchWorkItem` before controls ever
        // returns to the run loop, so the canceled item can never sneak in and execute. Interleaving
        // real sleeps between keystrokes (as an earlier version of this test did) doesn't strengthen
        // that guarantee and instead makes the test flaky under a busy test run (hundreds of other
        // `@MainActor` tests contending for the same serial executor can stretch a nominal "10ms"
        // sleep well past the 50ms debounce window, letting an earlier keystroke's timer fire for
        // real before the next keystroke gets a chance to cancel it).
        for chunk in ["a", "ab", "abc", "abcd"] {
            fire(coordinator, text: chunk)
        }

        // Nothing should have fired yet: every keystroke restarted the debounce timer before it fired,
        // and no suspension point occurred above for a stale timer to sneak through on.
        #expect(received.isEmpty)

        try? await Task.sleep(nanoseconds: 300_000_000) // let the final debounce actually fire, with generous slack

        #expect(received == ["abcd"])
    }

    @Test("deinit flushes a pending debounced edit synchronously instead of silently dropping it")
    func deinitFlushesPendingEdit() {
        var storedText = ""
        let binding = Binding(get: { storedText }, set: { storedText = $0 })
        var received: [String] = []
        // A debounce long enough that only `deinit`'s flush (not the timer) can deliver this edit.
        let editor = makeEditor(text: binding, debounceInterval: 10, onDebouncedChange: { received.append($0) })

        do {
            let coordinator = editor.makeCoordinator()
            fire(coordinator, text: "unsaved edit")
            // `coordinator` deallocates at the end of this scope, well before the 10s debounce timer
            // would ever fire on its own.
        }

        #expect(received == ["unsaved edit"])
    }

    @Test("deinit does not re-flush an edit that already fired via the debounce timer")
    func deinitDoesNotDoubleFlushAfterFiring() async {
        var storedText = ""
        let binding = Binding(get: { storedText }, set: { storedText = $0 })
        var received: [String] = []
        let editor = makeEditor(text: binding, debounceInterval: 0.02, onDebouncedChange: { received.append($0) })

        do {
            let coordinator = editor.makeCoordinator()
            fire(coordinator, text: "flushed already")
            try? await Task.sleep(nanoseconds: 150_000_000) // let the debounce timer fire on its own first
        }

        #expect(received == ["flushed already"])
    }

    @Test("with no edits made, deinit does not invoke onDebouncedChange at all")
    func deinitWithNoEditsDoesNotInvokeCallback() {
        var storedText = "initial"
        let binding = Binding(get: { storedText }, set: { storedText = $0 })
        var received: [String] = []
        let editor = makeEditor(text: binding, debounceInterval: 10, onDebouncedChange: { received.append($0) })

        do {
            _ = editor.makeCoordinator()
        }

        #expect(received.isEmpty)
    }
}
