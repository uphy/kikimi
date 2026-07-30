import Foundation

/// Pure parser for the `kikimi://` URL scheme (`docs/design/09-raycast-integration.md` section 3,
/// kikimi.md 10 章's Raycast 連携 subsection). Deliberately side-effect-free (no logging, no
/// `WindowManager` calls) so it is directly unit-testable, matching the same pattern
/// `TranscriptRowList`/`SessionListGrouping` use elsewhere in this codebase: callers (`AppDelegate`)
/// are responsible for logging when `parse(_:)` returns `nil` and for actually invoking
/// `WindowManager`.
enum KikimiURLRoute: Equatable {
    /// `kikimi://window/new` / `kikimi://window/new?based_on=<session-id>`. `basedOn` is passed
    /// through unvalidated (existence/format checks happen downstream in
    /// `SessionStore.createDraftSession(basedOn:)`, design doc section 4).
    case newWindow(basedOn: String?)
    /// `kikimi://record/quick`.
    case recordQuick
    /// `kikimi://debug/webview?target=<surface>&action=dump&out=<path>` /
    /// `...&action=click&testid=<id>` (`docs/design/39-webview-markdown.md` MD12 / §8.3).
    ///
    /// The verification hook for WebView-rendered surfaces. `kikimi-verify` runs outside the process
    /// and so cannot call `evaluateJavaScript` itself; this route is what lets it ask the app to.
    /// **Parsing is unconditional; acting on it is gated** on a test environment variable — see
    /// `DebugBridgeMode`, and the `AppDelegate` case that consults it.
    case debugWebView(target: DebugWebViewTarget, action: DebugWebViewAction)

    /// Which of the app's web views to talk to.
    enum DebugWebViewTarget: String, Equatable {
        case summary
        case watchers
        case chat
        /// The zoom overlay (`docs/design/40-diagram-zoom.md`).
        case diagram
    }

    enum DebugWebViewAction: Equatable {
        /// Writes the page's rendered text to `out`, or logs it when `out` is `nil`.
        case dump(out: String?)
        /// Clicks the element carrying `data-testid`. `out` receives `clicked` or `not-found`, so a
        /// script can tell the two apart without scraping the log.
        case click(testId: String, out: String?)
    }

    /// Returns `nil` for any URL that is not exactly one of the two recognized endpoints (wrong
    /// scheme, unknown host, unknown path, malformed URL). Never throws and never logs; see the
    /// type doc comment above.
    static func parse(_ url: URL) -> KikimiURLRoute? {
        guard url.scheme?.caseInsensitiveCompare("kikimi") == .orderedSame else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        switch (components.host, components.path) {
        case ("window", "/new"):
            // An explicitly empty `?based_on=` is normalized to `nil` (design doc section 3):
            // otherwise it would reach `SessionIdValidation.validate` downstream and fail as
            // `.invalidSessionId("")`, which is surprising for what is effectively "no based_on".
            let rawBasedOn = components.queryItems?.first(where: { $0.name == "based_on" })?.value
            let basedOn = (rawBasedOn?.isEmpty ?? true) ? nil : rawBasedOn
            return .newWindow(basedOn: basedOn)
        case ("record", "/quick"):
            return .recordQuick
        case ("debug", "/webview"):
            return parseDebugWebView(components)
        default:
            return nil
        }
    }

    /// Returns `nil` for a malformed debug URL rather than guessing: a verification script that
    /// mistypes a target should fail loudly instead of silently checking the wrong surface.
    private static func parseDebugWebView(_ components: URLComponents) -> KikimiURLRoute? {
        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { _, last in last }
        )
        guard let rawTarget = query["target"], let target = DebugWebViewTarget(rawValue: rawTarget) else { return nil }

        switch query["action"] {
        case "dump", nil:
            // `out` is optional: without it the text goes to the log, which is enough for a human
            // reading `log stream` but not for a script that wants to diff it.
            let out = query["out"]
            return .debugWebView(target: target, action: .dump(out: (out?.isEmpty ?? true) ? nil : out))
        case "click":
            guard let testId = query["testid"], !testId.isEmpty else { return nil }
            let out = query["out"]
            return .debugWebView(target: target, action: .click(testId: testId, out: (out?.isEmpty ?? true) ? nil : out))
        default:
            return nil
        }
    }
}

// MARK: - DebugBridgeMode

/// Whether the `kikimi://debug/...` routes are allowed to act
/// (`docs/design/39-webview-markdown.md` MD12).
///
/// Gated on the environment rather than on `#if DEBUG`: the builds that get verified are Release
/// builds (`mise run apply`), so a compile-time gate would put the hook in exactly the builds where
/// it is useless. `KIKIMI_DEBUG_BRIDGE` exists for manual poking; the other two mean a verification
/// run is already in progress.
enum DebugBridgeMode {
    static let isActive: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["KIKIMI_DEBUG_BRIDGE"] == "1"
            || environment["KIKIMI_TEST_HIDDEN"] == "1"
            || environment["KIKIMI_STUB_LLM"] == "1"
    }()
}
