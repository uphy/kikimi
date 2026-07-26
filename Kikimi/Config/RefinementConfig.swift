import Foundation
import OSLog

// MARK: - RefinementConfig

/// `refinement:` section of `config.yaml` (kikimi.md 12 章 / `docs/design/03-refinement-batch.md`
/// section 8). Drives `RefinementQueue`'s batch-flush thresholds, context-cache refresh cadence, and
/// the model passed to `LLMClient`.
///
/// Split out of `AppConfig.swift` into its own file (mirroring `DiarizationConfig.swift`/
/// `AudioConfig.swift`/`DictationConfig.swift`, each already one config section per file) purely to
/// keep `AppConfig.swift` under the project's `file_length` lint limit after `KikimiConfigData`
/// gained its `glossary` field (`docs/design/28-glossary.md` §2).
struct RefinementConfig: Codable, Equatable, Sendable {
    /// Claude model used for segment refinement (kikimi.md 7 章). Independent of `summary.model` /
    /// Watcher models (each is configured separately per kikimi.md 12 章).
    var model: String
    /// Batch flush threshold: once this many segments are queued, the batch is refined immediately
    /// even if `batchTimeoutMs` hasn't elapsed yet (kikimi.md 7 章 "10 セグメント溜まる").
    var batchSize: Int
    /// Batch flush threshold: milliseconds since the first segment in the current batch was enqueued
    /// before it is refined regardless of `batchSize` (kikimi.md 7 章 "最初のセグメント投入から 5 秒経過").
    var batchTimeoutMs: Int
    /// Number of preceding (refined-if-available, else raw) segments included as context in each
    /// batch's user prompt (kikimi.md 7 章 "直前3セグメント").
    var contextSegments: Int
    /// Number of batches between `context.md` cache-refresh rebuilds of the refinement system prompt
    /// (`docs/design/03-refinement-batch.md` section 4.3 / kikimi.md 7 章 "キャッシュ更新戦略").
    var contextRefreshBatches: Int
    /// Toggles the `docs/design/24-system-audio-leak-mitigation.md` §4.2 leak-dedup rule in the
    /// refinement system prompt (§4.3). Fixed for the lifetime of a session -- see that section's
    /// note on why this does not need `context_refresh_batches`-style live reload.
    var dedupSystemLeakSegments: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case batchSize = "batch_size"
        case batchTimeoutMs = "batch_timeout_ms"
        case contextSegments = "context_segments"
        case contextRefreshBatches = "context_refresh_batches"
        case dedupSystemLeakSegments = "dedup_system_leak_segments"
    }

    /// The exact defaults documented in kikimi.md 12 章's `config.yaml` sample.
    static let `default` = RefinementConfig(
        model: "claude-haiku-4-5-20251001",
        batchSize: 10,
        batchTimeoutMs: 5_000,
        contextSegments: 3,
        contextRefreshBatches: 10,
        dedupSystemLeakSegments: true
    )

    init(
        model: String,
        batchSize: Int,
        batchTimeoutMs: Int,
        contextSegments: Int,
        contextRefreshBatches: Int,
        dedupSystemLeakSegments: Bool = true
    ) {
        self.model = model
        self.batchSize = batchSize
        self.batchTimeoutMs = batchTimeoutMs
        self.contextSegments = contextSegments
        self.contextRefreshBatches = contextRefreshBatches
        self.dedupSystemLeakSegments = dedupSystemLeakSegments
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "RefinementConfig")

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial `refinement:` section (e.g.
    /// only `batch_size:`) fills every other field from `RefinementConfig.default` rather than failing
    /// the whole `config.yaml` decode. Additionally clamps out-of-range values to their default with a
    /// `.warning` log (`docs/design/03-refinement-batch.md` section 8's "値の妥当性ガード"), since these
    /// feed directly into `RefinementQueue`'s flush-timer arithmetic and array slicing, where a
    /// negative or zero value would misbehave rather than merely look wrong.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.default.model

        let decodedBatchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? Self.default.batchSize
        if decodedBatchSize < 1 {
            Self.logger.warning(
                "refinement.batch_size=\(decodedBatchSize, privacy: .public) must be >= 1; falling back to \(Self.default.batchSize, privacy: .public)"
            )
            batchSize = Self.default.batchSize
        } else {
            batchSize = decodedBatchSize
        }

        let decodedBatchTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .batchTimeoutMs) ?? Self.default.batchTimeoutMs
        if decodedBatchTimeoutMs < 0 {
            Self.logger.warning(
                "refinement.batch_timeout_ms=\(decodedBatchTimeoutMs, privacy: .public) must be >= 0; falling back to \(Self.default.batchTimeoutMs, privacy: .public)"
            )
            batchTimeoutMs = Self.default.batchTimeoutMs
        } else {
            batchTimeoutMs = decodedBatchTimeoutMs
        }

        let decodedContextSegments = try container.decodeIfPresent(Int.self, forKey: .contextSegments) ?? Self.default.contextSegments
        if decodedContextSegments < 0 {
            Self.logger.warning(
                "refinement.context_segments=\(decodedContextSegments, privacy: .public) must be >= 0; falling back to \(Self.default.contextSegments, privacy: .public)"
            )
            contextSegments = Self.default.contextSegments
        } else {
            contextSegments = decodedContextSegments
        }

        let decodedContextRefreshBatches =
            try container.decodeIfPresent(Int.self, forKey: .contextRefreshBatches) ?? Self.default.contextRefreshBatches
        if decodedContextRefreshBatches < 1 {
            Self.logger.warning(
                "refinement.context_refresh_batches=\(decodedContextRefreshBatches, privacy: .public) must be >= 1; falling back to \(Self.default.contextRefreshBatches, privacy: .public)"
            )
            contextRefreshBatches = Self.default.contextRefreshBatches
        } else {
            contextRefreshBatches = decodedContextRefreshBatches
        }

        dedupSystemLeakSegments =
            try container.decodeIfPresent(Bool.self, forKey: .dedupSystemLeakSegments) ?? Self.default.dedupSystemLeakSegments
    }
}
