import AppKit
import Testing

@testable import Kikimi

/// Layer 1 coverage for `DiagramZoomPlacement` (`docs/design/40-diagram-zoom.md` §4). The only
/// decision the overlay controller makes that is separable from AppKit: which screen to cover.
@Suite("DiagramZoomPlacement")
@MainActor
struct DiagramZoomPlacementTests {
    @Test("with no anchor window, the overlay falls back to the main screen")
    func fallsBackToMainScreen() {
        guard let mainScreen = NSScreen.main else { return }
        #expect(DiagramZoomPlacement.screenFrame(for: nil, mainScreen: mainScreen) == mainScreen.visibleFrame)
    }

    @Test("with neither an anchor nor a screen, a non-empty rect is still returned")
    func survivesHavingNoScreen() {
        // A zero-sized frame would make the panel unconstructible; the overlay is expected to
        // degrade rather than trap (headless runs, detached sessions).
        let frame = DiagramZoomPlacement.screenFrame(for: nil, mainScreen: nil)
        #expect(frame.width > 0)
        #expect(frame.height > 0)
    }

    @Test("the frame excludes the menu bar and Dock (visibleFrame, not frame)")
    func usesVisibleFrame() {
        guard let mainScreen = NSScreen.main, mainScreen.visibleFrame != mainScreen.frame else {
            // A screen with no menu bar inset (rare, but possible on a secondary display) makes this
            // indistinguishable; nothing to assert.
            return
        }
        #expect(DiagramZoomPlacement.screenFrame(for: nil, mainScreen: mainScreen) != mainScreen.frame)
    }
}
