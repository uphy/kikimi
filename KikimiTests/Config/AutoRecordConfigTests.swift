import Foundation
import Testing
import Yams

@testable import Kikimi

/// Decode defaults for `auto_record` (`docs/design/50-meet-auto-record.md` section 4).
@Suite("AutoRecordConfig")
struct AutoRecordConfigTests {
    private func decodeData(_ yaml: String) throws -> KikimiConfigData {
        try YAMLDecoder().decode(KikimiConfigData.self, from: yaml)
    }

    @Test("defaults are disabled with a 120 second grace")
    func defaults() {
        #expect(AutoRecordConfig.default.googleMeet.enabled == false)
        #expect(AutoRecordConfig.default.googleMeet.endGraceSeconds == 120)
        #expect(AutoRecordConfig.default.googleMeet.window == .stowed)
    }

    @Test("window decodes stowed/shown and falls back to stowed for unknown values")
    func windowMode() throws {
        let shown = try decodeData("auto_record:\n  google_meet:\n    window: shown")
        #expect(shown.autoRecord.googleMeet.window == .shown)
        let bogus = try decodeData("auto_record:\n  google_meet:\n    window: floating")
        #expect(bogus.autoRecord.googleMeet.window == .stowed)
    }

    @Test("a config without auto_record: falls back to the default")
    func missingSection() throws {
        let data = try decodeData("audio: {}")
        #expect(data.autoRecord == .default)
    }

    @Test("empty auto_record: and google_meet: sections fall back to the default")
    func emptySections() throws {
        #expect(try decodeData("auto_record: {}").autoRecord == .default)
        #expect(try decodeData("auto_record:\n  google_meet: {}").autoRecord == .default)
    }

    @Test("a partial google_meet section fills the missing key")
    func partialSection() throws {
        let enabledOnly = try decodeData("auto_record:\n  google_meet:\n    enabled: true")
        #expect(enabledOnly.autoRecord.googleMeet == GoogleMeetAutoRecordConfig(enabled: true, endGraceSeconds: 120))

        let graceOnly = try decodeData("auto_record:\n  google_meet:\n    end_grace_seconds: 0")
        #expect(graceOnly.autoRecord.googleMeet == GoogleMeetAutoRecordConfig(enabled: false, endGraceSeconds: 0))
    }

    @Test("a negative end_grace_seconds falls back to the default")
    func negativeGrace() throws {
        let data = try decodeData("auto_record:\n  google_meet:\n    end_grace_seconds: -5")
        #expect(data.autoRecord.googleMeet.endGraceSeconds == 120)
    }

    @Test("encoding round-trips with snake_case keys")
    func roundTrip() throws {
        var data = KikimiConfigData()
        data.autoRecord.googleMeet = GoogleMeetAutoRecordConfig(enabled: true, endGraceSeconds: 300)
        let yaml = try YAMLEncoder().encode(data)
        #expect(yaml.contains("auto_record"))
        #expect(yaml.contains("end_grace_seconds"))
        #expect(try decodeData(yaml).autoRecord == data.autoRecord)
    }
}
