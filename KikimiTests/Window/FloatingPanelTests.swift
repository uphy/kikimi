import AppKit
import Testing

@testable import Kikimi

// MARK: - FloatingPanel

/// Unit tests for `FloatingPanel`'s shared configuration (`docs/design/06-ui-panels.md` sections
/// 2-3, kikimi.md section 10 "NSPanel `.nonactivatingPanel` で常時最前面"). `FloatingPanel` is the
/// base every one of Kikimi's three window kinds (Session Window/Session List/Settings) is built
/// on; these tests pin the specific `NSPanel` properties its doc comment calls out as load-bearing,
/// each with a stated reason (key/main status, floating level, cross-Space visibility,
/// deactivate-hiding), so a regression in any one of them is caught here rather than only
/// discoverable interactively via `kikimi-verify`.
@Suite("FloatingPanel")
@MainActor
struct FloatingPanelTests {
    /// Production configuration by default. `isUnobtrusive` is passed explicitly rather than left to
    /// `HiddenTestMode`, because the suite itself runs with `KIKIMI_TEST_HIDDEN=1` (so a test run does
    /// not flash panels over the user's work) -- reading the environment here would silently test
    /// only the hidden branch.
    private func makePanel(isUnobtrusive: Bool = false) -> FloatingPanel {
        FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), isUnobtrusive: isUnobtrusive)
    }

    @Test("canBecomeKey/canBecomeMain are overridden to true so hosted text fields/NSTextViews can accept input")
    func canBecomeKeyAndMainAreTrue() {
        let panel = makePanel()
        #expect(panel.canBecomeKey)
        #expect(panel.canBecomeMain)
    }

    @Test("a panel is visible and interactive in production configuration")
    func productionPanelIsInteractive() {
        let panel = makePanel()
        #expect(panel.alphaValue == 1)
        #expect(!panel.ignoresMouseEvents)
    }

    @Test("an unobtrusive panel is transparent, takes no key status, and lets mouse events through")
    func unobtrusivePanelTouchesNothing() {
        // What `KIKIMI_TEST_HIDDEN=1` buys: a verification run (or a `swift test` run) must not appear
        // on screen, must not swallow the user's keystrokes, and must not eat their clicks. Being
        // invisible alone covers only the first.
        let panel = makePanel(isUnobtrusive: true)
        #expect(panel.alphaValue == 0)
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test("styleMask includes .nonactivatingPanel so the app never steals focus from whatever is in front")
    func styleMaskIncludesNonactivatingPanel() {
        let panel = makePanel()
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test("styleMask includes titled/closable/resizable/fullSizeContentView for normal window chrome")
    func styleMaskIncludesExpectedChromeOptions() {
        let panel = makePanel()
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.closable))
        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.styleMask.contains(.fullSizeContentView))
    }

    @Test("is a floating panel at the .floating level, so it stays above normal app windows")
    func isFloatingAtFloatingLevel() {
        let panel = makePanel()
        #expect(panel.isFloatingPanel)
        #expect(panel.level == .floating)
    }

    @Test("collectionBehavior includes canJoinAllSpaces and fullScreenAuxiliary for cross-Space visibility")
    func collectionBehaviorIncludesCrossSpaceOptions() {
        let panel = makePanel()
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test("hidesOnDeactivate is false, so the panel stays visible while another app is focused")
    func hidesOnDeactivateIsFalse() {
        let panel = makePanel()
        #expect(!panel.hidesOnDeactivate)
    }

    @Test("each call produces an independently-configured panel instance")
    func eachCallProducesIndependentInstance() {
        let first = makePanel()
        let second = makePanel()
        #expect(first !== second)
        #expect(second.isFloatingPanel)
        #expect(second.level == .floating)
    }
}
