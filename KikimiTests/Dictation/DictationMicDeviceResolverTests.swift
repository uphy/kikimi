import Foundation
import Testing

@testable import Kikimi

// MARK: - FakeMicDeviceEnumerator

/// Deterministic stand-in for `AudioInputEnumerator`, scoped to this file's own `resolve(...)`
/// tests (mirrors `MeetingWorkspaceViewModelTests`' own `FakeAudioInputEnumerator`, declared
/// separately since that one is `private` to its file).
private struct FakeMicDeviceEnumerator: AudioInputEnumerating {
    var devices: [AudioDeviceInfo] = []

    func inputDevices() -> [AudioDeviceInfo] { devices }
    func systemAudioProcesses() -> [AudioProcessInfo] { [] }
    func registeredSystemAudioApps() -> [AudioProcessInfo] { [] }
}

// MARK: - DictationMicDeviceResolver

@Suite("DictationMicDeviceResolver")
struct DictationMicDeviceResolverTests {
    @Test("empty configuredUID resolves to the system default input device's name, with no uid")
    func emptyConfiguredUIDResolvesToSystemDefault() {
        let info = DictationMicDeviceResolver.resolve(
            configuredUID: "",
            enumerator: FakeMicDeviceEnumerator(devices: [AudioDeviceInfo(uid: "some-uid", name: "Some Mic")]),
            systemDefaultDeviceName: { "Built-in Microphone" }
        )

        #expect(info.name == "Built-in Microphone")
        #expect(info.uid == nil)
    }

    @Test("a configuredUID matching an enumerated device resolves to that device's name and uid")
    func matchingConfiguredUIDResolvesToTheDevice() {
        let info = DictationMicDeviceResolver.resolve(
            configuredUID: "usb-mic-uid",
            enumerator: FakeMicDeviceEnumerator(devices: [
                AudioDeviceInfo(uid: "other-uid", name: "Other Mic"),
                AudioDeviceInfo(uid: "usb-mic-uid", name: "USB Mic")
            ]),
            systemDefaultDeviceName: { "Built-in Microphone" }
        )

        #expect(info.name == "USB Mic")
        #expect(info.uid == "usb-mic-uid")
    }

    @Test("a configuredUID with no matching device falls back to the system default (mirrors MicrophoneSource's own fallback), uid stays nil")
    func unresolvableConfiguredUIDFallsBackToSystemDefault() {
        let info = DictationMicDeviceResolver.resolve(
            configuredUID: "unplugged-uid",
            enumerator: FakeMicDeviceEnumerator(devices: [AudioDeviceInfo(uid: "other-uid", name: "Other Mic")]),
            systemDefaultDeviceName: { "Built-in Microphone" }
        )

        #expect(info.name == "Built-in Microphone")
        #expect(info.uid == nil)
    }

    @Test("no system default device available at all resolves to a nil name and nil uid")
    func noSystemDefaultDeviceResolvesToNilName() {
        let info = DictationMicDeviceResolver.resolve(
            configuredUID: "",
            enumerator: FakeMicDeviceEnumerator(devices: []),
            systemDefaultDeviceName: { nil }
        )

        #expect(info.name == nil)
        #expect(info.uid == nil)
    }
}
