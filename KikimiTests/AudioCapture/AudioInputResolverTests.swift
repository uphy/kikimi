import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `AudioInputResolver.resolve(selection:availableDevices:availableApps:phase:)`,
/// per `docs/design/10-audio-input-selection.md` section 9: "選択解決規則（4章）を pure function ...
/// として切り出し、全分岐をテスト（mic: UID あり/なし/未接続 × ①② / system: ①では検証しないこと・
/// ②で見つからなければ nil に落ちること / 有効・無効の直交）".
@Suite("AudioInputResolver")
struct AudioInputResolverTests {
    private static let knownDevice = AudioDeviceInfo(uid: "known-device", name: "Known Mic")
    private static let knownApp = AudioProcessInfo(bundleId: "known.app", displayName: "Known App")

    private static func selection(
        micEnabled: Bool = true,
        deviceUid: String? = nil,
        systemEnabled: Bool = true,
        bundleId: String? = nil
    ) -> AudioInputSelection {
        AudioInputSelection(
            mic: MicSelection(enabled: micEnabled, deviceUid: deviceUid),
            system: SystemAudioSelection(enabled: systemEnabled, bundleId: bundleId)
        )
    }

    // MARK: - Mic: UID present and connected

    @Test("mic deviceUid that exists among availableDevices is left unchanged at phase ① (windowOpen)")
    func micConnectedUidUnchangedAtWindowOpen() {
        let resolved = AudioInputResolver.resolve(
            selection: Self.selection(deviceUid: Self.knownDevice.uid),
            availableDevices: [Self.knownDevice],
            availableApps: [],
            phase: .windowOpen
        )
        #expect(resolved.mic.deviceUid == Self.knownDevice.uid)
    }

    @Test("mic deviceUid that exists among availableDevices is left unchanged at phase ② (recordingStart)")
    func micConnectedUidUnchangedAtRecordingStart() {
        let resolved = AudioInputResolver.resolve(
            selection: Self.selection(deviceUid: Self.knownDevice.uid),
            availableDevices: [Self.knownDevice],
            availableApps: [],
            phase: .recordingStart
        )
        #expect(resolved.mic.deviceUid == Self.knownDevice.uid)
    }

    // MARK: - Mic: UID present but not connected (section 4 ①/②, failure mode #2/#8)

    @Test("mic deviceUid not among availableDevices is reset to nil at phase ① (windowOpen)")
    func micDisconnectedUidResetAtWindowOpen() {
        let resolved = AudioInputResolver.resolve(
            selection: Self.selection(deviceUid: "unplugged-uid"),
            availableDevices: [Self.knownDevice],
            availableApps: [],
            phase: .windowOpen
        )
        #expect(resolved.mic.deviceUid == nil)
    }

    @Test("mic deviceUid not among availableDevices is reset to nil at phase ② (recordingStart)")
    func micDisconnectedUidResetAtRecordingStart() {
        let resolved = AudioInputResolver.resolve(
            selection: Self.selection(deviceUid: "unplugged-uid"),
            availableDevices: [Self.knownDevice],
            availableApps: [],
            phase: .recordingStart
        )
        #expect(resolved.mic.deviceUid == nil)
    }

    @Test("mic deviceUid resolution applies even when the mic is disabled (enabled/disabled are orthogonal)")
    func micUidResolutionIgnoresEnabledFlag() {
        let resolved = AudioInputResolver.resolve(
            selection: Self.selection(micEnabled: false, deviceUid: "unplugged-uid"),
            availableDevices: [Self.knownDevice],
            availableApps: [],
            phase: .windowOpen
        )
        #expect(resolved.mic.deviceUid == nil)
        #expect(resolved.mic.enabled == false, "resolve() must never flip `enabled`, only `deviceUid`")
    }

    // MARK: - Mic: no explicit UID (system default)

    @Test("mic deviceUid == nil (system default) stays nil at both phases")
    func micNilUidStaysNil() {
        let atWindowOpen = AudioInputResolver.resolve(
            selection: Self.selection(deviceUid: nil),
            availableDevices: [Self.knownDevice],
            availableApps: [],
            phase: .windowOpen
        )
        let atRecordingStart = AudioInputResolver.resolve(
            selection: Self.selection(deviceUid: nil),
            availableDevices: [Self.knownDevice],
            availableApps: [],
            phase: .recordingStart
        )
        #expect(atWindowOpen.mic.deviceUid == nil)
        #expect(atRecordingStart.mic.deviceUid == nil)
    }

    // MARK: - System: not validated at phase ① (section 4's table, row 2)

    @Test("system bundleId not among availableApps is left unchanged (not validated) at phase ① (windowOpen)")
    func systemBundleIdUnresolvedAtWindowOpen() {
        let resolved = AudioInputResolver.resolve(
            selection: Self.selection(bundleId: "not.running.app"),
            availableDevices: [],
            availableApps: [Self.knownApp],
            phase: .windowOpen
        )
        #expect(resolved.system.bundleId == "not.running.app", "phase ① must never touch system.bundleId")
    }

    // MARK: - System: validated at phase ② (section 4's table, row 2/3, section 8 failure mode #3)

    @Test("system bundleId that exists among availableApps is left unchanged at phase ② (recordingStart)")
    func systemRunningBundleIdUnchangedAtRecordingStart() {
        let resolved = AudioInputResolver.resolve(
            selection: Self.selection(bundleId: Self.knownApp.bundleId),
            availableDevices: [],
            availableApps: [Self.knownApp],
            phase: .recordingStart
        )
        #expect(resolved.system.bundleId == Self.knownApp.bundleId)
    }

    @Test("system bundleId not among availableApps is reset to nil at phase ② (recordingStart)")
    func systemMissingBundleIdResetAtRecordingStart() {
        let resolved = AudioInputResolver.resolve(
            selection: Self.selection(bundleId: "not.running.app"),
            availableDevices: [],
            availableApps: [Self.knownApp],
            phase: .recordingStart
        )
        #expect(resolved.system.bundleId == nil)
    }

    @Test("system bundleId resolution applies even when system audio is disabled (enabled/disabled are orthogonal)")
    func systemBundleIdResolutionIgnoresEnabledFlag() {
        let resolved = AudioInputResolver.resolve(
            selection: Self.selection(systemEnabled: false, bundleId: "not.running.app"),
            availableDevices: [],
            availableApps: [Self.knownApp],
            phase: .recordingStart
        )
        #expect(resolved.system.bundleId == nil)
        #expect(resolved.system.enabled == false, "resolve() must never flip `enabled`, only `bundleId`")
    }

    // MARK: - System: no explicit bundleId (all system audio)

    @Test("system bundleId == nil (all system audio) stays nil at both phases")
    func systemNilBundleIdStaysNil() {
        let atWindowOpen = AudioInputResolver.resolve(
            selection: Self.selection(bundleId: nil),
            availableDevices: [],
            availableApps: [Self.knownApp],
            phase: .windowOpen
        )
        let atRecordingStart = AudioInputResolver.resolve(
            selection: Self.selection(bundleId: nil),
            availableDevices: [],
            availableApps: [Self.knownApp],
            phase: .recordingStart
        )
        #expect(atWindowOpen.system.bundleId == nil)
        #expect(atRecordingStart.system.bundleId == nil)
    }

    // MARK: - Combined: mic and system resolved independently

    @Test("mic and system are resolved independently of each other at phase ② (recordingStart)")
    func micAndSystemResolvedIndependently() {
        let resolved = AudioInputResolver.resolve(
            selection: Self.selection(deviceUid: Self.knownDevice.uid, bundleId: "not.running.app"),
            availableDevices: [Self.knownDevice],
            availableApps: [Self.knownApp],
            phase: .recordingStart
        )
        #expect(resolved.mic.deviceUid == Self.knownDevice.uid, "mic UID is still connected, must not be reset")
        #expect(resolved.system.bundleId == nil, "system app is gone, must be reset")
    }
}
