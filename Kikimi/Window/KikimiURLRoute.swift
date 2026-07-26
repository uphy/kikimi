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
        default:
            return nil
        }
    }
}
