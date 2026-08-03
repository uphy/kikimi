import Foundation

/// Pure parser for the `kikimi://` URL scheme (`docs/design/09-raycast-integration.md` section 3,
/// kikimi.md 10 章's Raycast 連携 subsection). Deliberately side-effect-free (no logging, no
/// `WindowManager` calls) so it is directly unit-testable, matching the same pattern
/// `TranscriptRowList`/`SessionListGrouping` use elsewhere in this codebase: callers (`AppDelegate`)
/// are responsible for logging when `parse(_:)` returns `nil` and for actually invoking
/// `WindowManager`.
enum KikimiURLRoute: Equatable {
    /// `kikimi://window/new` / `?based_on=<session-id>` / `?profile=<profile-id>`
    /// (`docs/design/41-meeting-profiles.md` §7). `seed` is passed through unvalidated
    /// (existence/format checks happen downstream in `SessionStore.createDraftSession(seed:)`,
    /// design doc section 4).
    case newWindow(seed: DraftSeed)
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
        /// The Summary tab's meeting-state pane -- and the whole summary when the template could not
        /// be split (`docs/design/47-summary-split-pane.md` §4.3). Existing verification scenarios
        /// that look for 概要/決定事項/アクションアイテム keep working unchanged; ones looking for 議事詳細
        /// content need `summaryTopics` below.
        case summary
        case summaryTopics
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
            return parseNewWindow(components)
        case ("record", "/quick"):
            return .recordQuick
        case ("debug", "/webview"):
            return parseDebugWebView(components)
        default:
            return nil
        }
    }

    /// Returns `nil` when both `based_on` and `profile` are specified (design doc §7): letting
    /// either one silently win would misrepresent the caller's intent, so this fails loudly the
    /// same way `parseDebugWebView` does for a malformed target/action.
    private static func parseNewWindow(_ components: URLComponents) -> KikimiURLRoute? {
        // An explicitly empty value is normalized to absent (design doc section 3 / §7):
        // otherwise it would reach downstream validation and fail as e.g. `.invalidSessionId("")`,
        // which is surprising for what is effectively "no based_on" / "no profile".
        let basedOn = nonEmptyQueryValue("based_on", in: components)
        let profile = nonEmptyQueryValue("profile", in: components)

        switch (basedOn, profile) {
        case (nil, nil):
            return .newWindow(seed: .none)
        case let (basedOn?, nil):
            return .newWindow(seed: .basedOn(sessionId: basedOn))
        case let (nil, profile?):
            return .newWindow(seed: .profile(id: profile))
        case (.some, .some):
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

    /// The first value of the named query item, with an explicitly empty value normalized to
    /// absent. Shared by `parseNewWindow`'s `based_on` / `profile` handling (design doc §3 / §7):
    /// an empty query value and an omitted one both mean "not specified".
    private static func nonEmptyQueryValue(_ name: String, in components: URLComponents) -> String? {
        let raw = components.queryItems?.first(where: { $0.name == name })?.value
        return (raw?.isEmpty ?? true) ? nil : raw
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
