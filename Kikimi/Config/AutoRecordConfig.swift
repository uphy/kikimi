import Foundation
import OSLog

// MARK: - GoogleMeetAutoRecordConfig

/// `auto_record.google_meet.window`: whether an auto-started recording opens its Session Window
/// (design 50 section 3.6).
enum AutoRecordWindowMode: String, Codable, Equatable, Sendable {
    /// Record without showing the window (it is stowed).
    case stowed
    /// Show the window when recording starts.
    case shown
}

/// `auto_record.google_meet` (`docs/design/50-meet-auto-record.md` section 4).
struct GoogleMeetAutoRecordConfig: Codable, Equatable, Sendable {
    /// Opt-in: off by default.
    var enabled: Bool
    /// Seconds between detecting a leave and ending the session. `0` means "never auto-end"
    /// (the session stays Paused).
    var endGraceSeconds: Int
    var window: AutoRecordWindowMode

    enum CodingKeys: String, CodingKey {
        case enabled
        case endGraceSeconds = "end_grace_seconds"
        case window
    }

    static let `default` = GoogleMeetAutoRecordConfig(enabled: false, endGraceSeconds: 120, window: .stowed)

    init(enabled: Bool, endGraceSeconds: Int, window: AutoRecordWindowMode = .stowed) {
        self.enabled = enabled
        self.endGraceSeconds = endGraceSeconds
        self.window = window
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "AutoRecordConfig")

    /// Missing keys fall back to `.default`; a negative grace falls back too (with a warning).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.default.enabled
        // An unknown value (typo in config.yaml) falls back to the default instead of failing the whole config.
        window = (try? container.decodeIfPresent(AutoRecordWindowMode.self, forKey: .window)) ?? Self.default.window
        let grace = try container.decodeIfPresent(Int.self, forKey: .endGraceSeconds)
            ?? Self.default.endGraceSeconds
        if grace < 0 {
            Self.logger.warning("auto_record.google_meet.end_grace_seconds is negative (\(grace)); using default")
            endGraceSeconds = Self.default.endGraceSeconds
        } else {
            endGraceSeconds = grace
        }
    }
}

// MARK: - AutoRecordConfig

/// `auto_record:` section of `config.yaml`.
struct AutoRecordConfig: Codable, Equatable, Sendable {
    var googleMeet: GoogleMeetAutoRecordConfig

    enum CodingKeys: String, CodingKey {
        case googleMeet = "google_meet"
    }

    static let `default` = AutoRecordConfig(googleMeet: .default)

    init(googleMeet: GoogleMeetAutoRecordConfig) {
        self.googleMeet = googleMeet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        googleMeet = try container.decodeIfPresent(GoogleMeetAutoRecordConfig.self, forKey: .googleMeet)
            ?? .default
    }
}
