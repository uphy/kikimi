import Foundation
import OSLog

// MARK: - SummaryConfig

/// `summary:` section of `config.yaml` (kikimi.md 12 章, `docs/design/04-summary-updater.md` §8).
/// Wired into `AppConfig`/`KikimiConfigData` (`Kikimi/Config/AppConfig.swift`) and consumed by
/// `MeetingWorkspaceViewModel.defaultSummaryUpdaterFactory`
/// (`MeetingWorkspaceViewModel+Factories.swift`), which passes `AppConfig.shared.data.summary`
/// instead of a struct-literal default.
///
/// Split out of `SummaryUpdater.swift` purely for `file_length` (mirrors `+FinalTitle.swift`/
/// `+Regeneration.swift`/`+ParticipantsMerge.swift`/`+FinalPass.swift`'s own splits of that file) --
/// this is a plain `Codable` config struct, not an `extension SummaryUpdater`, but it lived inside
/// `SummaryUpdater.swift` itself until `docs/design/44-llm-model-config.md` §7's `final_model` field
/// pushed that file over the line limit.
struct SummaryConfig: Codable, Sendable, Equatable {
    /// `summary.model`. Independent of `refinement.model` / Watcher models (kikimi.md 12 章: each is
    /// configured separately). Drives the incremental update / full regeneration / final-title flows;
    /// `finalModel` below is the session-end final pass's own separate assignment.
    var model: String
    /// `summary.final_model` (`docs/design/44-llm-model-config.md` §2.2, new in this module).
    /// `ModelRef` string for the session-end final refinement pass (`+FinalPass.swift`) only. `nil`
    /// (or empty -- `ModelResolver.resolve` treats an empty candidate the same as an absent one)
    /// means "not configured": resolved via the candidate list `[finalModel, model]`
    /// (`ModelResolver.resolve(candidates:...)`), never `finalModel ?? model` collapsed into one value
    /// first -- §3.2 explicitly bans that shortcut because it cannot fall through to `model` when
    /// `finalModel` is *defined but invalid* (an unknown alias, say), only when it is unset.
    var finalModel: String?
    /// `summary.update_trigger_segments`.
    var updateTriggerSegments: Int
    /// `summary.update_trigger_seconds`.
    var updateTriggerSeconds: Int
    /// `summary.auto_naming`. When `false`, every auto-title mechanism in §3 is suppressed (the
    /// summary body itself still updates normally).
    var autoNaming: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case finalModel = "final_model"
        case updateTriggerSegments = "update_trigger_segments"
        case updateTriggerSeconds = "update_trigger_seconds"
        case autoNaming = "auto_naming"
    }

    /// The exact defaults documented in kikimi.md 12 章's `config.yaml` sample. `finalModel` defaults
    /// to `nil` (unset) -- kikimi.md 12 章's sample config sets `summary.final_model: premium`
    /// explicitly rather than relying on this struct default.
    static let `default` = SummaryConfig(
        model: "claude-haiku-4-5-20251001",
        finalModel: nil,
        updateTriggerSegments: 20,
        updateTriggerSeconds: 180,
        autoNaming: true
    )

    /// Every parameter defaults to `SummaryConfig.default`'s own value so existing call sites that
    /// construct this with only a subset of fields (e.g. `SummaryConfig(updateTriggerSegments: 1)` in
    /// `SummaryUpdaterTests`/`MeetingWorkspaceViewModelTests`) keep compiling unchanged even though
    /// `init(from:)` below suppresses the memberwise initializer Swift would otherwise synthesize.
    init(
        model: String = "claude-haiku-4-5-20251001",
        finalModel: String? = nil,
        updateTriggerSegments: Int = 20,
        updateTriggerSeconds: Int = 180,
        autoNaming: Bool = true
    ) {
        self.model = model
        self.finalModel = finalModel
        self.updateTriggerSegments = updateTriggerSegments
        self.updateTriggerSeconds = updateTriggerSeconds
        self.autoNaming = autoNaming
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SummaryConfig")

    /// Custom decoder mirroring `RefinementConfig.init(from:)` (`Kikimi/Config/AppConfig.swift`): a
    /// partial (or absent) `summary:` section fills every missing field from `SummaryConfig.default`
    /// rather than failing the whole `config.yaml` decode. `update_trigger_segments`/
    /// `update_trigger_seconds` are additionally clamped to their default with a `.warning` log when
    /// out of range, since they feed directly into `SummaryUpdater`'s flush-timer arithmetic where a
    /// negative or zero value would misbehave rather than merely look wrong. `final_model` needs no
    /// such clamp -- an absent/empty value is simply "not configured" (see the stored property's doc
    /// comment above), not a value that could misbehave arithmetically.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.default.model
        finalModel = try container.decodeIfPresent(String.self, forKey: .finalModel)

        let decodedUpdateTriggerSegments =
            try container.decodeIfPresent(Int.self, forKey: .updateTriggerSegments) ?? Self.default.updateTriggerSegments
        if decodedUpdateTriggerSegments < 1 {
            Self.logger.warning(
                """
                summary.update_trigger_segments=\(decodedUpdateTriggerSegments, privacy: .public) must be >= 1; \
                falling back to \(Self.default.updateTriggerSegments, privacy: .public)
                """
            )
            updateTriggerSegments = Self.default.updateTriggerSegments
        } else {
            updateTriggerSegments = decodedUpdateTriggerSegments
        }

        let decodedUpdateTriggerSeconds =
            try container.decodeIfPresent(Int.self, forKey: .updateTriggerSeconds) ?? Self.default.updateTriggerSeconds
        if decodedUpdateTriggerSeconds < 0 {
            Self.logger.warning(
                """
                summary.update_trigger_seconds=\(decodedUpdateTriggerSeconds, privacy: .public) must be >= 0; \
                falling back to \(Self.default.updateTriggerSeconds, privacy: .public)
                """
            )
            updateTriggerSeconds = Self.default.updateTriggerSeconds
        } else {
            updateTriggerSeconds = decodedUpdateTriggerSeconds
        }

        autoNaming = try container.decodeIfPresent(Bool.self, forKey: .autoNaming) ?? Self.default.autoNaming
    }
}
