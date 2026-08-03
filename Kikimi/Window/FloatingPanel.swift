import AppKit
import SwiftUI

// MARK: - HiddenTestMode

/// `KIKIMI_TEST_HIDDEN=1` (kikimi-verify skill / `mise run verify-smoke`, docs in
/// `~/.claude/skills/kikimi-verify/SKILL.md`): drives every window kind (Session Window / Session
/// List / Settings) fully off-screen so automated verification never flashes a visible panel or
/// steals the user's frontmost app, while keeping the AX tree populated (`FloatingPanel` still
/// orders the window in normally -- only `alphaValue` goes to 0 -- so `System Events`/AX clicks,
/// which walk the accessibility tree rather than rendered pixels, keep working). Read once at
/// process start, same rationale as `TestModeIndicator`
/// (`Kikimi/Views/MeetingWorkspace/TestModeBanner.swift`): env is fixed for a process's lifetime,
/// so this is a pure static lookup with no per-call `ProcessInfo` cost.
enum HiddenTestMode {
    /// True under the env flag, and also whenever the process is a test runner. `mise run test`
    /// and CI export the flag, but a bare `swift test` (easy to reach for during development)
    /// does not -- the runner probe catches that case so window suites never flash real panels over
    /// the user's work. `FloatingPanelTests` is unaffected: it injects `isUnobtrusive` explicitly to
    /// cover both branches.
    static let isActive: Bool = {
        if ProcessInfo.processInfo.environment["KIKIMI_TEST_HIDDEN"] == "1" { return true }
        // Kept as one of the signals, but no longer the only one -- see `isTestRunner`.
        if NSClassFromString("XCTestCase") != nil { return true }
        return isTestRunner(
            processName: ProcessInfo.processInfo.processName,
            arguments: ProcessInfo.processInfo.arguments
        )
    }()

    /// Whether this process is a SwiftPM/Xcode test runner rather than the app.
    ///
    /// The previous probe was `NSClassFromString("XCTestCase") != nil` alone, on the assumption that
    /// "XCTest is linked into every SwiftPM test runner (including swift-testing suites)". That
    /// stopped being true once the last `import XCTest` left `KikimiTests/`: a swift-testing-only
    /// bundle runs under `swiftpm-testing-helper --testing-library swift-testing`, which never loads
    /// XCTest, so the probe silently returned `false` and a bare `swift test` ordered real, fully
    /// opaque panels (Session Window, Session List, the ディクテーション overlay, …) onto the user's
    /// desktop mid-run. Verified 2026-08-03 by polling `CGWindowListCopyWindowInfo` during a run.
    ///
    /// So the process itself is identified instead, by two independent signals -- either the runner
    /// executable's name, or the `.xctest` bundle every runner is pointed at. Neither can occur in
    /// the shipped app: `Kikimi.app`'s process is `Kikimi` and nothing on its command line ends in
    /// `.xctest`.
    ///
    /// Pure (arguments injected) so both branches are unit-testable regardless of how the suite that
    /// checks them happens to be run.
    static func isTestRunner(processName: String, arguments: [String]) -> Bool {
        if processName == "xctest" || processName == "swiftpm-testing-helper" { return true }
        return arguments.contains { $0.hasSuffix(".xctest") || $0.contains(".xctest/") }
    }
}

// MARK: - FloatingPanel

/// The shared `NSPanel` base for every Kikimi floating window (Session Window, Session List,
/// Settings). See `docs/design/06-ui-panels.md` sections 2-3 and kikimi.md section 10
/// ("NSPanel `.nonactivatingPanel` で常時最前面").
///
/// Modeled after Chirami's `NotePanel`/`NoteWindow.swift` (`docs/references/chirami-map.md`
/// section 3), but intentionally does **not** carry over Chirami's note-specific features: pin/
/// always-on-top toggle, transparency, warp-key (hjkl) navigation, periodic rollover navigation
/// buttons, or custom titlebar chrome. Kikimi's "meeting workspace" windows are task-oriented
/// (Draft → Recording → Ended) rather than long-lived notes, so those productivity features have
/// no equivalent requirement here (`docs/design/06-ui-panels.md` section 2 diff table).
class FloatingPanel: NSPanel {
    /// The designated initializer, threading `isUnobtrusive` in before `NSWindow`'s own runs — a
    /// `let` cannot be assigned after `self.init(...)`, and `canBecomeKey` is consulted during
    /// window setup.
    init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool, isUnobtrusive: Bool) {
        self.isUnobtrusive = isUnobtrusive
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
    }

    /// A `.nonactivatingPanel` defaults to `canBecomeKey == false`, which would make it
    /// impossible to type into any text field or `NSTextView` hosted inside it (e.g. the Prep
    /// tab editors, the inline title rename field). Overriding lets the panel accept key status
    /// when the user interacts with it, without the *app* itself becoming active and stealing
    /// focus from whatever app the user is currently in (the whole point of `.nonactivatingPanel`).
    ///
    /// **Except when `isUnobtrusive`**: this machine is also used for real work, and "invisible" is
    /// not the same as "harmless". A transparent panel that takes key status still swallows the
    /// user's keystrokes mid-sentence. Refusing key status there costs nothing that matters, because
    /// AX-driven operations (`ax_click.py` / `tab_click.py`) do not need a key window — verified
    /// 2026-07-30 by driving the tab bar and the WebView dump bridge against a fully transparent,
    /// non-key window.
    override var canBecomeKey: Bool { !isUnobtrusive }
    override var canBecomeMain: Bool { !isUnobtrusive }

    /// Whether this panel must not appear on screen or take any input.
    ///
    /// Defaults to `HiddenTestMode.isActive` (`KIKIMI_TEST_HIDDEN=1`), which both `kikimi-verify` and
    /// `swift test` set — the unit suites order real windows in, and without this a test run flashes
    /// panels over whatever the user is doing.
    ///
    /// Injectable rather than read straight from the environment so the tests can exercise *both*
    /// branches: asserting `canBecomeKey` against `HiddenTestMode.isActive` would only ever check
    /// whichever branch the suite happened to run under, leaving the production one unverified.
    let isUnobtrusive: Bool

    /// Chrome variant. `.titled` is every existing Kikimi window (Session Window / Session List /
    /// Settings / the D2 misfire-guard `DictationOverlayPanel`); `.borderless` is for
    /// display-only HUDs that need no title bar, close box, or resize handles -- the dictation
    /// live-preview HUD (`docs/design/25-dictation-mode.md`'s "ライブプレビューHUD" section) is the
    /// first user.
    enum Style {
        case titled
        case borderless
    }

    /// Creates a panel pre-configured with the styling/behavior shared by every Kikimi floating
    /// window. Callers (window controllers) remain responsible for `title`, restoring saved
    /// position/size, and installing their content view. `style` defaults to `.titled` so every
    /// existing call site is unaffected.
    convenience init(contentRect: NSRect, style: Style = .titled, isUnobtrusive: Bool = HiddenTestMode.isActive) {
        let styleMask: NSWindow.StyleMask
        switch style {
        case .titled:
            styleMask = [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView]
        case .borderless:
            styleMask = [.nonactivatingPanel, .fullSizeContentView, .borderless]
        }
        self.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false,
            isUnobtrusive: isUnobtrusive
        )

        // Float above other windows/apps without ever activating Kikimi or stealing key focus
        // on its own (kikimi.md section 10: "NSPanel `.nonactivatingPanel` で常時最前面").
        isFloatingPanel = true
        // Set explicitly rather than relying solely on `isFloatingPanel`'s level side effect --
        // matches Chirami's `NoteWindow`, which sets `level` directly (`chirami-map.md` 3 章).
        level = .floating

        // Stay visible across every Space, including the active Space of a full-screened app,
        // so the transcript/summary panel remains reachable while the user is in a meeting app.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Don't hide the panel just because Kikimi (the app) is deactivated -- the whole point
        // of a floating meeting workspace is that it stays visible while another app is focused.
        hidesOnDeactivate = false

        if style == .borderless {
            // A borderless HUD paints its own rounded-rect background in SwiftUI
            // (`DictationLiveHUDView`'s `.clipShape`/`.background`); the panel itself must stay
            // transparent everywhere outside that shape, and needs a shadow to read as "floating"
            // the way a titled window's own chrome shadow normally provides.
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
        }

        // `KIKIMI_TEST_HIDDEN=1` (see `HiddenTestMode` above): still order the window in as normal
        // (so `showWindow`/`makeKeyAndOrderFront` and the AX tree behave exactly as in production --
        // System Events' AX clicks, which `kikimi-verify`'s `ax_click.py` relies on, need the window
        // present in the accessibility tree), but make it fully transparent so nothing ever paints
        // on screen and no screenshot/`screencapture` can show it.
        if isUnobtrusive {
            alphaValue = 0
            // An invisible window that still hit-tests is worse than a visible one: the user clicks
            // where they expect their editor to be and the click disappears into Kikimi. Letting
            // mouse events pass straight through removes that entirely. AX-driven clicks are
            // unaffected (they never go through hit testing), and coordinate clicks are not usable
            // against a transparent window anyway.
            ignoresMouseEvents = true
        }
    }
}

// MARK: - FirstMouseHostingView

/// An `NSHostingView` that treats the click which makes its `FloatingPanel` key as a normal click
/// on its SwiftUI content, instead of AppKit's default of swallowing it purely to activate the
/// window. Without this, the *first* click after a panel opens (or regains key status) -- e.g. on
/// a `TabView` tab item -- just brings the panel forward and is discarded, requiring a second
/// click to actually register; every following click works because the panel is already key.
/// `NSView.acceptsFirstMouse(for:)` defaults to `false` for exactly this reason (to stop a
/// focus-bringing click from also triggering destructive controls), but Kikimi's floating panels
/// are meant to act like utility panels where a single click both focuses and acts -- the same
/// tradeoff Chirami's `NoteWebView` makes (`docs/references/chirami-map.md` 3 章).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
