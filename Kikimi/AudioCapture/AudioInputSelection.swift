import Foundation

// MARK: - MicSelection

/// Microphone choice. `deviceUid == nil` means "follow the system default input device".
/// See `docs/design/10-audio-input-selection.md` section 2.
struct MicSelection: Codable, Equatable, Sendable {
    var enabled: Bool
    var deviceUid: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case deviceUid = "device_uid"
    }
}

// MARK: - SystemAudioSelection

/// System audio choice. `bundleId == nil` means "All System Audio"
/// (the current global exclude-list tap). Non-nil limits capture to the processes
/// belonging to that application bundle. See `docs/design/10-audio-input-selection.md` section 2.
struct SystemAudioSelection: Codable, Equatable, Sendable {
    var enabled: Bool
    var bundleId: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case bundleId = "bundle_id"
    }
}

// MARK: - AudioInputSelection

/// "What to capture and where from" for a single recording. Shared by the UI, persistence
/// (`AppState.lastAudioInput`), and `AudioCapture`. See `docs/design/10-audio-input-selection.md`
/// section 2.
struct AudioInputSelection: Codable, Equatable, Sendable {
    var mic: MicSelection
    var system: SystemAudioSelection

    /// Both sources enabled: default input device + all system audio.
    static let `default` = AudioInputSelection(
        mic: MicSelection(enabled: true, deviceUid: nil),
        system: SystemAudioSelection(enabled: true, bundleId: nil)
    )

    var hasEnabledSource: Bool { mic.enabled || system.enabled }
}
