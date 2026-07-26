import CoreAudio
import Testing

@testable import Kikimi

// MARK: - OutputRouteClassification

/// Layer 1 (unit) coverage for `docs/design/24-system-audio-leak-mitigation.md` §5.1/§8's pure
/// classification function. `OutputRouteMonitor` itself (the CoreAudio polling wrapper) is real-device
/// dependent and deliberately left out of this test target's scope (design §8, layer 1 bullet).
@Suite("OutputRouteClassification")
struct OutputRouteClassificationTests {
    @Test("kAudioDeviceTransportTypeBuiltIn classifies as .builtInSpeaker")
    func builtInTransportTypeClassifiesAsBuiltInSpeaker() {
        #expect(OutputRouteClassification.classify(transportType: kAudioDeviceTransportTypeBuiltIn) == .builtInSpeaker)
    }

    @Test("Bluetooth/USB/HDMI/AirPlay/Virtual transport types all classify as .other")
    func nonBuiltInTransportTypesClassifyAsOther() {
        let nonBuiltInTransportTypes: [UInt32] = [
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeUnknown
        ]
        for transportType in nonBuiltInTransportTypes {
            #expect(OutputRouteClassification.classify(transportType: transportType) == .other)
        }
    }
}
