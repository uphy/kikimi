import AVFoundation
import Foundation

// MARK: - DictationMicDeviceResolver

/// Pure resolution logic for "which microphone did this utterance actually capture from"
/// (`docs/design/29-dictation-history.md` §3.2 addendum, added alongside the "入力" tab's mic
/// `Picker`), mirroring `DictationContextResolver`'s pure-function style: takes every input the
/// real caller (`DictationController.handleHotkeyDown()`) has and returns what to record, so it is
/// unit-testable without touching real CoreAudio hardware.
enum DictationMicDeviceResolver {
    /// `entry.json`'s `mic_device_name`/`mic_device_uid` pair for one utterance
    /// (`DictationHistoryEntry`).
    struct MicDeviceInfo: Equatable, Sendable {
        /// The device name actually used to capture -- always populated when a device could be
        /// determined at all (either the resolved `configuredUID` match, or the system default
        /// input device's name).
        var name: String?
        /// The resolved CoreAudio device UID, only when `configuredUID` was non-empty and matched a
        /// device `enumerator.inputDevices()` currently reports. `nil` whenever the system default
        /// input device was used instead, mirroring `MicrophoneSource.deviceUID == nil`.
        var uid: String?
    }

    /// - Parameters:
    ///   - configuredUID: `dictation.mic_device_uid` verbatim (empty string means "system default",
    ///     matching `DictationConfig.micDeviceUID`'s own contract).
    ///   - enumerator: `AudioInputEnumerator` in production; a fake in tests.
    ///   - systemDefaultDeviceName: Resolves the system default input device's display name.
    ///     Injectable (default: `AVCaptureDevice.default(for: .audio)?.localizedName`) so tests
    ///     never have to depend on real hardware being present.
    ///
    /// Mirrors `MicrophoneSource.configureInputDevice(deviceUID:on:)`'s fallback rule (a non-empty
    /// but unresolvable UID falls back to the system default, logged there as a warning). Best
    /// effort: this resolves via AVCaptureDevice enumeration at key-down, while `MicrophoneSource`
    /// opens via CoreAudio -- if that open itself fails after enumeration succeeded, the recorded
    /// device can differ from the one actually captured.
    static func resolve(
        configuredUID: String,
        enumerator: any AudioInputEnumerating,
        systemDefaultDeviceName: () -> String? = { AVCaptureDevice.default(for: .audio)?.localizedName }
    ) -> MicDeviceInfo {
        if !configuredUID.isEmpty, let match = enumerator.inputDevices().first(where: { $0.uid == configuredUID }) {
            return MicDeviceInfo(name: match.name, uid: match.uid)
        }
        return MicDeviceInfo(name: systemDefaultDeviceName(), uid: nil)
    }
}
