import Foundation
import Testing

@testable import Kikimi

// MARK: - CopyFeedbackFlash

/// Unit tests for `CopyFeedbackFlash` (`Kikimi/Views/MeetingWorkspace/MeetingTabView.swift`), which
/// its own doc comment calls out as factored out of `MeetingTabView.copyMenu`'s
/// `.task(id: copyFeedbackToken)` closure specifically so this logic "stays directly unit-testable
/// without instantiating a SwiftUI view" (`docs/design/37-transcript-markdown-copy.md` §3.3/TC11).
@Suite("CopyFeedbackFlash")
struct CopyFeedbackFlashTests {
    @Test("does not flash on the view's very first `.task(id:)` firing (the initial copyFeedbackToken value must never be treated as \"a copy just happened\")")
    func doesNotFlashOnFirstObservation() {
        #expect(CopyFeedbackFlash.shouldFlash(hasObservedInitialToken: false) == false)
    }

    @Test("flashes on every firing after the first (each one was triggered by an actual copyFeedbackToken bump from a successful copy)")
    func flashesOnEverySubsequentObservation() {
        #expect(CopyFeedbackFlash.shouldFlash(hasObservedInitialToken: true) == true)
    }
}
