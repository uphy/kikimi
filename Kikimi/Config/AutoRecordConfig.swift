import Foundation
import OSLog

// MARK: - GoogleMeetAutoRecordConfig

/// `auto_record.google_meet` (`docs/design/50-meet-auto-record.md` section 4).
struct GoogleMeetAutoRecordConfig: Codable, Equatable, Sendable {
    /// Opt-in: off by default.
    var enabled: Bool
    /// Seconds between detecting a leave and ending the session. `0` means "never auto-end"
    /// (the session stays Paused).
    var endGraceSeconds: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case endGraceSeconds = "end_grace_seconds"
    }

    static let `default` = GoogleMeetAutoRecordConfig(enabled: false, endGraceSeconds: 120)

    init(enabled: Bool, endGraceSeconds: Int) {
        self.enabled = enabled
        self.endGraceSeconds = endGraceSeconds
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "AutoRecordConfig")

    /// Missing keys fall back to `.default`; a negative grace falls back too (with a warning).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.default.enabled
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
