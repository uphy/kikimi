import Foundation

// MARK: - AudioConfig

/// `audio:` section of `config.yaml` (`docs/design/24-system-audio-leak-mitigation.md` section 5.3).
///
/// Deliberately narrow in scope: `01-audio-capture.md` section 11's `audio.format`/`audio.sample_rate`/
/// `audio.channels` are read from a separate, pre-`KikimiConfigData` config-loading layer that feeds
/// `AudioCaptureConfig` directly (that section's own doc comment) and are **not** modeled here. This
/// struct only carries the toggle `OutputRouteMonitor` needs -- see that section's rationale for why a
/// new top-level `audio:` struct was introduced rather than reusing (or renaming) that other path.
struct AudioConfig: Codable, Equatable, Sendable {
    /// `false` disables `OutputRouteMonitor` entirely: `MeetingWorkspaceViewModel` does not construct
    /// or start one on Recording entry, so `WorkspaceBanner.builtInSpeakerOutputDetected` never fires
    /// (design section 5.1's "`OutputRouteMonitor` はこの ... 値を Recording 開始時に読み、`false` なら
    /// `OutputRouteMonitor` 自体を起動しない").
    var suggestHeadphonesOnBuiltInSpeaker: Bool

    enum CodingKeys: String, CodingKey {
        case suggestHeadphonesOnBuiltInSpeaker = "suggest_headphones_on_builtin_speaker"
    }

    /// The exact default documented in design section 5.3/9's `config.yaml` sample.
    static let `default` = AudioConfig(suggestHeadphonesOnBuiltInSpeaker: true)

    init(suggestHeadphonesOnBuiltInSpeaker: Bool) {
        self.suggestHeadphonesOnBuiltInSpeaker = suggestHeadphonesOnBuiltInSpeaker
    }

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `audio:` section
    /// fills the missing field from `.default` instead of failing the whole `config.yaml` decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        suggestHeadphonesOnBuiltInSpeaker = try container.decodeIfPresent(
            Bool.self, forKey: .suggestHeadphonesOnBuiltInSpeaker
        ) ?? Self.default.suggestHeadphonesOnBuiltInSpeaker
    }
}
