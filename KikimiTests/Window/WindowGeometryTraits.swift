import Foundation
import Testing

/// Shared condition trait for the window-controller tests that assert on an `NSWindow`'s exact
/// resulting frame origin.
extension Trait where Self == ConditionTrait {
    /// Gates tests whose expectations only hold when the window server leaves a requested frame
    /// alone.
    ///
    /// macOS constrains a window's frame against the screen it lands on, and how much it moves it
    /// depends on that screen's geometry -- the menu bar, the Dock, and whether the window is
    /// ordered in at the time. On a developer's machine these tests' frames sit comfortably inside
    /// the visible area and pass through untouched; on a GitHub Actions runner the same frames come
    /// back shifted (e.g. a saved origin of `y: 20` observed as `y: 82`), so the assertions fail for
    /// a reason that has nothing to do with the code under test.
    ///
    /// Only assertions about the *exact origin AppKit ended up with* are gated this way. Everything
    /// those same suites cover that does not depend on the host's screen -- minimum-size clamping,
    /// debounced persistence, coalescing, stow/unstow state -- still runs everywhere, and the
    /// persistence tests compare against `window.frame` precisely so they stay valid on a screen
    /// that constrains it.
    static var requiresUnconstrainedWindowGeometry: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["CI"] == nil,
            "asserts on an exact NSWindow frame origin, which the window server adjusts differently depending on the host screen"
        )
    }
}
