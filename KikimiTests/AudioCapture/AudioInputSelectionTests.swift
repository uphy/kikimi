import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `AudioInputSelection`/`MicSelection`/`SystemAudioSelection`, per
/// `docs/design/10-audio-input-selection.md` section 9's "Codable round-trip" requirement:
/// snake_case keys, `nil` serialized as key omission, and decode accepting both explicit `null`
/// and key omission.
@Suite("AudioInputSelection")
struct AudioInputSelectionTests {
    // MARK: - default

    @Test("default selection enables both sources with no explicit device/app")
    func defaultSelection() {
        let selection = AudioInputSelection.default
        #expect(selection.mic.enabled)
        #expect(selection.mic.deviceUid == nil)
        #expect(selection.system.enabled)
        #expect(selection.system.bundleId == nil)
        #expect(selection.hasEnabledSource)
    }

    @Test("hasEnabledSource is false only when both sources are disabled")
    func hasEnabledSourceReflectsBothFlags() {
        var selection = AudioInputSelection.default
        selection.mic.enabled = false
        #expect(selection.hasEnabledSource) // system still enabled

        selection.system.enabled = false
        #expect(!selection.hasEnabledSource)

        selection.mic.enabled = true
        #expect(selection.hasEnabledSource)
    }

    // MARK: - Round-trip

    @Test("round-trips through JSON with non-nil device/bundle ids")
    func roundTripsWithValues() throws {
        let original = AudioInputSelection(
            mic: MicSelection(enabled: true, deviceUid: "BuiltInMicrophoneDevice"),
            system: SystemAudioSelection(enabled: false, bundleId: "us.zoom.xos")
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioInputSelection.self, from: data)

        #expect(decoded == original)
    }

    @Test("round-trips through JSON when device/bundle ids are nil")
    func roundTripsWithNils() throws {
        let original = AudioInputSelection.default

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioInputSelection.self, from: data)

        #expect(decoded == original)
    }

    // MARK: - snake_case keys

    @Test("encodes device_uid/bundle_id as snake_case keys")
    func encodesSnakeCaseKeys() throws {
        let selection = AudioInputSelection(
            mic: MicSelection(enabled: true, deviceUid: "abc"),
            system: SystemAudioSelection(enabled: true, bundleId: "us.zoom.xos")
        )

        let data = try JSONEncoder().encode(selection)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let mic = object?["mic"] as? [String: Any]
        let system = object?["system"] as? [String: Any]

        #expect(mic?["device_uid"] as? String == "abc")
        #expect(system?["bundle_id"] as? String == "us.zoom.xos")
    }

    // MARK: - nil serializes as key omission

    @Test("nil deviceUid is serialized as key omission, not explicit null")
    func nilDeviceUidOmitsKey() throws {
        let mic = MicSelection(enabled: true, deviceUid: nil)
        let data = try JSONEncoder().encode(mic)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?.keys.contains("device_uid") == false)
    }

    @Test("nil bundleId is serialized as key omission, not explicit null")
    func nilBundleIdOmitsKey() throws {
        let system = SystemAudioSelection(enabled: true, bundleId: nil)
        let data = try JSONEncoder().encode(system)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?.keys.contains("bundle_id") == false)
    }

    // MARK: - Decoding both explicit null and key omission

    @Test("decodes deviceUid as nil when the key is entirely omitted")
    func decodesMicWithOmittedKey() throws {
        let json = "{\"enabled\": true}"
        let mic = try JSONDecoder().decode(MicSelection.self, from: Data(json.utf8))

        #expect(mic == MicSelection(enabled: true, deviceUid: nil))
    }

    @Test("decodes deviceUid as nil when the key is explicit null")
    func decodesMicWithExplicitNull() throws {
        let json = "{\"enabled\": true, \"device_uid\": null}"
        let mic = try JSONDecoder().decode(MicSelection.self, from: Data(json.utf8))

        #expect(mic == MicSelection(enabled: true, deviceUid: nil))
    }

    @Test("decodes bundleId as nil when the key is entirely omitted")
    func decodesSystemWithOmittedKey() throws {
        let json = "{\"enabled\": true}"
        let system = try JSONDecoder().decode(SystemAudioSelection.self, from: Data(json.utf8))

        #expect(system == SystemAudioSelection(enabled: true, bundleId: nil))
    }

    @Test("decodes bundleId as nil when the key is explicit null")
    func decodesSystemWithExplicitNull() throws {
        let json = "{\"enabled\": true, \"bundle_id\": null}"
        let system = try JSONDecoder().decode(SystemAudioSelection.self, from: Data(json.utf8))

        #expect(system == SystemAudioSelection(enabled: true, bundleId: nil))
    }

    @Test("decodes the full kikimi.md state.yaml sample shape from JSON equivalent")
    func decodesFullSampleShape() throws {
        let json = """
        {
          "mic": { "enabled": true, "device_uid": "BuiltInMicrophoneDevice" },
          "system": { "enabled": true, "bundle_id": "us.zoom.xos" }
        }
        """
        let selection = try JSONDecoder().decode(AudioInputSelection.self, from: Data(json.utf8))

        #expect(selection.mic.enabled)
        #expect(selection.mic.deviceUid == "BuiltInMicrophoneDevice")
        #expect(selection.system.enabled)
        #expect(selection.system.bundleId == "us.zoom.xos")
    }
}
