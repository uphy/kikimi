import Testing

@testable import Kikimi

/// Layer 1 coverage for `docs/design/30-settings-ui-polish.md` §3's `clamped(to:)` -- the setter
/// half of `SettingsIntField`/`SettingsDoubleField`'s bindings, which bounds typed-in values into
/// the same range the fields' steppers enforce. The SwiftUI views themselves are layer-2 territory.
@Suite("SettingsFormControls")
struct SettingsFormControlsTests {
    @Test("clamped(to:) bounds values below the range up to its lower bound")
    func clampsBelowLowerBound() {
        #expect(5.clamped(to: 20...400) == 20)
        #expect((-1.0).clamped(to: 0.0...1.0) == 0.0)
    }

    @Test("clamped(to:) bounds values above the range down to its upper bound")
    func clampsAboveUpperBound() {
        #expect(9_999.clamped(to: 20...400) == 400)
        #expect(1.5.clamped(to: 0.0...1.0) == 1.0)
    }

    @Test("clamped(to:) leaves in-range values (including the bounds themselves) unchanged")
    func passesThroughInRangeValues() {
        #expect(120.clamped(to: 20...400) == 120)
        #expect(20.clamped(to: 20...400) == 20)
        #expect(400.clamped(to: 20...400) == 400)
        #expect(0.45.clamped(to: 0.0...1.0) == 0.45)
    }
}
