import Foundation

// MARK: - AudioInputResolutionPhase

/// The two moments at which `AudioInputSelection` is validated against the currently-enumerated
/// devices/apps and, if needed, destructively reset back to the default (`nil`) choice.
/// See `docs/design/10-audio-input-selection.md` section 4.
enum AudioInputResolutionPhase: Equatable, Sendable {
    /// ① Window open/reopen (`MeetingWorkspaceViewModel.hydrateFromSessionHandle()`), or a
    /// `refreshAudioInputs()` call while Draft/`.disabledOtherRecording`. Only the microphone
    /// `deviceUid` is validated; the system audio `bundleId` is intentionally left unchecked here
    /// -- an app that simply hasn't started producing audio yet (e.g. before a meeting begins) is
    /// not "gone", and resolving it away every time a window opens would defeat the point of
    /// remembering the last-used selection (section 4).
    case windowOpen
    /// ② The start of `MeetingWorkspaceViewModel.startRecording()`. Both the microphone
    /// `deviceUid` and the system audio `bundleId` are validated against the current enumeration.
    case recordingStart
}

// MARK: - AudioInputResolver

/// Pure resolution rule (`docs/design/10-audio-input-selection.md` section 4): given the current
/// `selection` and what is actually enumerated right now, destructively resets any selected target
/// that no longer exists back to its default (`nil` = system default input device / all system
/// audio). Never touches `enabled`; only `deviceUid`/`bundleId`, and only for the axis the given
/// `phase` validates.
///
/// A free function rather than a method so it stays trivially unit-testable in isolation, per
/// section 9's "選択解決規則（4章）を pure function ... として切り出し、全分岐をテスト" requirement.
enum AudioInputResolver {
    static func resolve(
        selection: AudioInputSelection,
        availableDevices: [AudioDeviceInfo],
        availableApps: [AudioProcessInfo],
        phase: AudioInputResolutionPhase
    ) -> AudioInputSelection {
        var resolved = selection

        // Mic UID validation happens at both phases (①/②), independent of `mic.enabled` (section
        // 9: "有効・無効の直交" -- the two axes are orthogonal, so a disabled mic's stale UID is
        // still resolved away rather than left dangling).
        if let deviceUid = resolved.mic.deviceUid, !availableDevices.contains(where: { $0.uid == deviceUid }) {
            resolved.mic.deviceUid = nil
        }

        // System bundle id validation only happens at phase ② (section 4's table, row 2).
        if phase == .recordingStart,
           let bundleId = resolved.system.bundleId,
           !availableApps.contains(where: { $0.bundleId == bundleId }) {
            resolved.system.bundleId = nil
        }

        return resolved
    }
}
