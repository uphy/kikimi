import Foundation
import OSLog

// MARK: - DiarizationConfig

/// `diarization:` section of `config.yaml` (`docs/design/13-speaker-diarization.md` section 7).
/// Alongside `RefinementConfig`, `LLMConfig`, `SttConfig`, `WatchersConfig`, `ExportConfig`
/// (`AppConfig.swift`), and `SummaryConfig` (`Kikimi/Summary/SummaryUpdater.swift`), the only sections
/// `AppConfig` currently models — every other `config.yaml` section from kikimi.md 12 章 (`storage`/
/// `audio`/`defaults`/`appearance`) is still read from hardcoded defaults at each of its own call sites
/// (`MeetingWorkspaceViewModel+Factories.swift`'s doc comments), so `AppConfig`/`KikimiConfigData` grow
/// to cover them only once those components are implemented.
///
/// Split into its own file (rather than living alongside the other `Codable` config sections in
/// `AppConfig.swift`) purely to keep that file under the project's `file_length` lint limit — this type
/// has no other reason to be separate from the rest of `AppConfig.swift`'s sections.
struct DiarizationConfig: Codable, Equatable, Sendable {
    /// `false` disables the feature entirely: system-audio segments keep the current physical-source
    /// "system" label with no per-speaker distinction (design section 7, "false で本機能を丸ごと無効化").
    var enabled: Bool
    /// Display name for `mic` segments (design section 4.5). Diarization never runs on the mic
    /// stream — the user is always the sole mic speaker.
    var selfName: String
    /// LS-EEND streaming step size, milliseconds (100 or 500; design section 2.1/7). Converted to
    /// FluidAudio's `LSEENDStepSize` via `LSEENDStepSize.fromDiarizationConfig(stepMs:logger:)`
    /// (`Kikimi/Diarization/DiarizationBackend.swift`) and passed into `LSEENDDiarizationBackend` by
    /// `MeetingWorkspaceViewModel.defaultDiarizationCoordinatorFactory`
    /// (`MeetingWorkspaceViewModel+Diarization.swift`). Any value other than `100`/`500` is logged as a
    /// warning and falls back to `500`.
    var stepMs: Int
    /// LS-EEND model variant (`callhome`/`dihard3`/`dihard2`/`ami`). Converted via
    /// `LSEENDVariant.fromDiarizationConfig(name:logger:)` (`Kikimi/Diarization/DiarizationBackend
    /// .swift`, which also documents why the default is `callhome` rather than the design's original
    /// `dihard3`). Unknown values are logged as a warning and fall back to `callhome`.
    var variant: String
    /// Minimum cumulative speech (ms) a slot needs before a voiceprint is extracted for it (design
    /// section 5, R2 scope — `WeSpeaker`/`voiceprints.json` do not exist yet, so this field is
    /// currently inert, kept here so `config.yaml` round-trips the full section from day one).
    var minEnrollSpeechMs: Int
    /// Voiceprint-match acceptance threshold (design section 2.2/7; R2 scope, currently inert like
    /// `minEnrollSpeechMs` above).
    var speakerMatchThreshold: Double
    /// Minimum cosine-distance gap a voiceprint match's nearest speaker must keep over the runner-up
    /// (a different-named registered speaker) to be accepted
    /// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 3/3.4:
    /// `VoiceprintMatchPolicy.decide(candidate:threshold:margin:)`'s `margin` parameter). `0` disables
    /// the margin check entirely, reproducing the pre-margin "distance < threshold" behavior (design
    /// section 3.4: "0 でマージン判定を無効化（従来挙動）").
    var speakerMatchMargin: Double

    enum CodingKeys: String, CodingKey {
        case enabled
        case selfName = "self_name"
        case stepMs = "step_ms"
        case variant
        case minEnrollSpeechMs = "min_enroll_speech_ms"
        case speakerMatchThreshold = "speaker_match_threshold"
        case speakerMatchMargin = "speaker_match_margin"
    }

    /// The exact defaults documented in design section 7's `config.yaml` sample, plus
    /// `speakerMatchMargin`'s own default (`docs/design/20-voiceprint-misassignment-mitigation.md`
    /// section 3.4).
    ///
    /// `speakerMatchThreshold` was lowered from the original placeholder `0.65` to `0.45` after
    /// real usage data showed the higher value flagging distinct, never-averaged real speakers as
    /// same-person suspects in the Settings 話者 tab (cosine distances of 0.51/0.60 between three
    /// genuinely different people, both under 0.65) -- exactly the "実測分布を取ってから閾値既定値の
    /// 変更を判断する" recalibration `docs/design/20-voiceprint-misassignment-mitigation.md` section
    /// 447 flagged as a future step. This is the same threshold live diarization uses to accept an
    /// auto-match (`RealtimeDiarizationCoordinator`), so the tighter value also makes auto-matching
    /// during a meeting stricter, not just the Settings warning quieter.
    static let `default` = DiarizationConfig(
        enabled: true,
        selfName: "自分",
        stepMs: 500,
        variant: "callhome",
        minEnrollSpeechMs: 5_000,
        speakerMatchThreshold: 0.45,
        speakerMatchMargin: 0.05
    )

    init(
        enabled: Bool,
        selfName: String,
        stepMs: Int,
        variant: String,
        minEnrollSpeechMs: Int,
        speakerMatchThreshold: Double,
        speakerMatchMargin: Double
    ) {
        self.enabled = enabled
        self.selfName = selfName
        self.stepMs = stepMs
        self.variant = variant
        self.minEnrollSpeechMs = minEnrollSpeechMs
        self.speakerMatchThreshold = speakerMatchThreshold
        self.speakerMatchMargin = speakerMatchMargin
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DiarizationConfig")

    /// Custom decoder so a user hand-editing `config.yaml` (12 章's documented workflow -- unlike
    /// `state.yaml`, this file is expected to be manually edited) can write a *partial*
    /// `diarization:` section (e.g. only `enabled: false`) without failing the whole `config.yaml`
    /// decode. Every field falls back to `DiarizationConfig.default`'s value when missing, mirroring
    /// `KikimiConfigData.init(from:)`'s leniency for a missing `diarization:` key entirely -- without
    /// this, a synthesized `Decodable` conformance would `throw` on any missing key and
    /// `KikimiConfigData`'s own `decodeIfPresent(DiarizationConfig.self, ...)` would treat that throw
    /// exactly like a present-but-malformed section, discarding the whole `diarization:` section
    /// (including the fields the user *did* write) rather than just filling the gap.
    ///
    /// `speakerMatchMargin` additionally clamps a negative value to `0` (design section 3.4: "負値は 0
    /// にクランプする — 実質「マージン無効」と等価だが仕様として明示しテスト可能にする") rather than falling back to
    /// `.default`'s `0.05` the way the other numeric fields above do -- a negative margin is not a
    /// malformed config so much as an explicit (if backwards) request to disable the margin check, and
    /// `0` is exactly what disabling it means (`VoiceprintMatchPolicy.decide`'s doc comment).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.default.enabled
        selfName = try container.decodeIfPresent(String.self, forKey: .selfName) ?? Self.default.selfName
        stepMs = try container.decodeIfPresent(Int.self, forKey: .stepMs) ?? Self.default.stepMs
        variant = try container.decodeIfPresent(String.self, forKey: .variant) ?? Self.default.variant
        minEnrollSpeechMs = try container.decodeIfPresent(Int.self, forKey: .minEnrollSpeechMs) ?? Self.default.minEnrollSpeechMs
        speakerMatchThreshold = try container.decodeIfPresent(Double.self, forKey: .speakerMatchThreshold) ?? Self.default.speakerMatchThreshold

        let decodedSpeakerMatchMargin = try container.decodeIfPresent(
            Double.self, forKey: .speakerMatchMargin
        ) ?? Self.default.speakerMatchMargin
        if decodedSpeakerMatchMargin < 0 {
            Self.logger.warning(
                """
                diarization.speaker_match_margin=\(decodedSpeakerMatchMargin, privacy: .public) must be \
                >= 0; clamping to 0 (margin check disabled)
                """
            )
            speakerMatchMargin = 0
        } else {
            speakerMatchMargin = decodedSpeakerMatchMargin
        }
    }
}
