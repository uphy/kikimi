import FluidAudio
import Foundation
import OSLog

// MARK: - DiarizationBackend

/// Abstraction over the diarization SDK call, mirroring `SttStreamingBackend`'s isolation goal
/// (`Kikimi/Stt/SttStreamingBackend.swift`): `RealtimeDiarizationCoordinator` only ever talks to this
/// protocol, never to FluidAudio's `LSEENDDiarizer` directly, so a future model/vendor swap only
/// touches this file plus `LSEENDDiarizationBackend`'s replacement.
///
/// Also the layer-1 test seam (`docs/design/13-speaker-diarization.md` section 11): a fake conforming
/// to this protocol drives `RealtimeDiarizationCoordinator`'s state machine deterministically without
/// a real model, CoreML, or network access.
///
/// `Sendable` because the coordinator (an `actor`) `await`s these calls across a suspension point
/// (model load, CoreML inference), and the result must be safely handed back to the coordinator's
/// executor on resume. `LSEENDDiarizer` itself is a plain `final class` with no isolation of its own,
/// so the production conformance (`LSEENDDiarizationBackend`) wraps it in its own `actor` rather than
/// exposing it (or a struct wrapping a reference to it) directly — no `@unchecked Sendable` anywhere.
protocol DiarizationBackend: Sendable {
    /// Loads the diarization model. Called at most once per backend instance's lifetime, the first
    /// time `RealtimeDiarizationCoordinator` ever needs to diarize (design section 5.1, "初回録音開始").
    /// Every later "(re)作成" reuses the already-loaded model via `reset()` instead of calling this
    /// again — see `RealtimeDiarizationCoordinator.beginSegment(startMsOffset:hasSystemAudio:)`.
    ///
    /// - Throws: On model download/initialization failure (design section 8, "diarization モデルの
    ///   ダウンロード失敗"). The coordinator treats this as fatal for the rest of the session (best-effort
    ///   degradation, never propagated to the recording/STT path).
    func initialize() async throws

    /// Feeds one buffer of 16 kHz mono samples into the diarizer's input queue. Does not itself return
    /// output — call `process()` afterward to drain it (mirrors `LSEENDDiarizer.addAudio(_:sourceSampleRate:)`
    /// / `.process()` being two separate calls).
    func addAudio(_ samples: [Float]) async throws

    /// Drains whatever `addAudio(_:)` has queued through the model and returns newly available
    /// finalized/tentative segments, or `nil` if nothing new was produced yet (design section 5;
    /// `LSEENDDiarizer.process()`).
    func process() async throws -> DiarizerTimelineUpdate?

    /// Ends the current streaming generation: drains the model's remaining right-context lookahead
    /// (via injected silence) and returns the last finalized segments (design section 5.1, "区間終了時
    /// のドレインと flush"). **Treated as terminal** by this backend/coordinator pair — the coordinator
    /// always follows this with `reset()` before diarizing again, never with more `addAudio`/`process()`
    /// calls against the same generation. See `LSEENDDiarizationBackend.finalizeSession()`'s doc comment
    /// for why.
    func finalizeSession() async throws -> DiarizerTimelineUpdate?

    /// Resets streaming state (feature buffers, frame cursor, speaker slots) while keeping the loaded
    /// model, starting a fresh generation whose internal speaker indices restart at 0 (design section
    /// 5.1, "（再）作成後は内部 index が 0 から始まる"). Never throws — `LSEENDDiarizer.reset()` itself cannot
    /// fail.
    func reset() async
}

// MARK: - DiarizationBackendError

/// Programming-error guard for `LSEENDDiarizationBackend`: every protocol method except
/// `initialize()` requires a loaded model. `RealtimeDiarizationCoordinator` never calls them before
/// `initialize()` has succeeded, so this case should be unreachable in practice.
enum DiarizationBackendError: LocalizedError, Equatable {
    case notInitialized

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Diarization backend method called before initialize() succeeded."
        }
    }
}

// MARK: - LSEENDStepSize + config wiring

extension LSEENDStepSize {
    /// Converts `DiarizationConfig.stepMs` (`config.yaml`'s `diarization.step_ms`,
    /// `Kikimi/Config/AppConfig.swift`; design section 7: "100/500") into FluidAudio's step-size enum.
    /// Only `100`/`500` are documented/supported values (design section 2.1's "レイテンシは 1 秒程度まで
    /// 許容" pins `.step500ms` as the baseline; `100` is the only other value 7 章 documents). Anything
    /// else is user misconfiguration -- logged per kikimi.md's logging rules ("Misconfiguration or
    /// missing resource" → `.warning`) and folded back to `.step500ms` rather than crashing or picking
    /// an arbitrary FluidAudio step size the design never discusses.
    static func fromDiarizationConfig(stepMs: Int, logger: Logger) -> LSEENDStepSize {
        switch stepMs {
        case 100:
            return .step100ms
        case 500:
            return .step500ms
        default:
            logger.warning(
                "diarization.step_ms=\(stepMs, privacy: .public) is not a supported value (100 or 500); falling back to 500ms"
            )
            return .step500ms
        }
    }
}

// MARK: - LSEENDVariant + config wiring

extension LSEENDVariant {
    /// Converts `DiarizationConfig.variant` (`config.yaml`'s `diarization.variant`) into FluidAudio's
    /// LS-EEND variant enum. The default is `.callhome`, not the design's originally chosen
    /// `.dihard3`: measured on a real Zoom-compressed Japanese meeting recording (2026-07-03, via
    /// `fluidaudiocli lseend` on the identical WAV), dihard3 merged virtually all speech into one
    /// speaker (376s vs 1.1s) while callhome separated two speakers cleanly (365s vs 68s) — telephone
    /// conversation being the closest training domain to codec-compressed online-meeting audio.
    /// Unknown values are user misconfiguration: logged as `.warning` and folded back to `.callhome`.
    static func fromDiarizationConfig(name: String, logger: Logger) -> LSEENDVariant {
        switch name.lowercased() {
        case "callhome":
            return .callhome
        case "dihard3":
            return .dihard3
        case "dihard2":
            return .dihard2
        case "ami":
            return .ami
        default:
            logger.warning(
                "diarization.variant=\(name, privacy: .public) is not a supported value (callhome/dihard3/dihard2/ami); falling back to callhome"
            )
            return .callhome
        }
    }
}

// MARK: - LSEENDDiarizationBackend

/// Production `DiarizationBackend` backed by FluidAudio's `LSEENDDiarizer` (design section 2.1: LS-EEND
/// streaming, dihard3 variant). An `actor` — not a `struct` wrapping a reference, unlike
/// `FluidAudioStreamingBackend` (`SttStreamingBackend.swift`) — because `LSEENDDiarizer` is a plain
/// class with no isolation of its own (the ASR streaming manager `FluidAudioStreamingBackend` wraps,
/// `StreamingNemotronMultilingualAsrManager`, is already an actor; `LSEENDDiarizer` is not), so this
/// type supplies that isolation itself rather than reaching for `@unchecked Sendable`.
actor LSEENDDiarizationBackend: DiarizationBackend {
    private let variant: LSEENDVariant
    private let stepSize: LSEENDStepSize
    private let onsetThreshold: Double
    private let offsetThreshold: Double
    private let minDurationOnMs: Int
    private let minDurationOffMs: Int
    private var diarizer: LSEENDDiarizer?

    /// - Parameters:
    ///   - variant: Defaults to `.callhome` (see `LSEENDVariant.fromDiarizationConfig(name:logger:)`
    ///     for why callhome, not the design's original dihard3). The production call site derives this
    ///     from `config.yaml`'s `diarization.variant` rather than relying on the default.
    ///   - stepSize: Defaults to `.step500ms` (design section 2.1/7: "レイテンシは 1 秒程度まで許容"), but
    ///     the production call site (`MeetingWorkspaceViewModel
    ///     .defaultDiarizationCoordinatorFactory`) always passes the value derived from `config.yaml`'s
    ///     `diarization.step_ms` via `LSEENDStepSize.fromDiarizationConfig(stepMs:logger:)` above rather
    ///     than relying on this default.
    ///   - onsetThreshold / offsetThreshold / minDurationOnMs / minDurationOffMs: `config.yaml`'s
    ///     `diarization.onset_threshold`/`offset_threshold`/`min_duration_on_ms`/`min_duration_off_ms`
    ///     (already range-validated by `DiarizationConfig.init(from:)`), turned into a
    ///     `DiarizerTimelineConfig` by `makeTimelineConfig(frameDurationSeconds:)` below. Defaults
    ///     mirror `DiarizationConfig.default`.
    init(
        variant: LSEENDVariant = .callhome,
        stepSize: LSEENDStepSize = .step500ms,
        onsetThreshold: Double = DiarizationConfig.default.onsetThreshold,
        offsetThreshold: Double = DiarizationConfig.default.offsetThreshold,
        minDurationOnMs: Int = DiarizationConfig.default.minDurationOnMs,
        minDurationOffMs: Int = DiarizationConfig.default.minDurationOffMs
    ) {
        self.variant = variant
        self.stepSize = stepSize
        self.onsetThreshold = onsetThreshold
        self.offsetThreshold = offsetThreshold
        self.minDurationOnMs = minDurationOnMs
        self.minDurationOffMs = minDurationOffMs
    }

    /// Loads the model and hands `LSEENDDiarizer` an explicit `DiarizerTimelineConfig`.
    ///
    /// **Why this open-codes `LSEENDDiarizer`'s own convenience initializer** (`LSEENDDiarizer(variant:
    /// stepSize:timelineConfig:)`, which does exactly this `loadFromHuggingFace` → `init(model:
    /// timelineConfig:)` pair): `DiarizerTimelineConfig` stores its duration gates as **frame counts**,
    /// and its seconds-valued accessors (`minDurationOn`, `onsetPadSeconds`, …) convert using whatever
    /// `frameDurationSeconds` the struct holds *at assignment time*. `init(model:timelineConfig:)` then
    /// overwrites `frameDurationSeconds` with the loaded model's metadata **without** recomputing those
    /// frame counts — so any config built before the model is loaded ends up with gates measured
    /// against the placeholder frame duration (0.08 s or 0.1 s), not the real one. Loading the model
    /// first and only then converting ms → frames against `model.metadata.frameDurationSeconds`
    /// (`timelineFrames(ms:frameDurationSeconds:)`) is the only way to get the durations the user
    /// actually configured.
    ///
    /// `LSEENDModel.loadFromHuggingFace` downloads/loads into FluidAudio's own cache
    /// (`~/Library/Application Support/FluidAudio/Models/` — kikimi.md 4 章) with
    /// `computeUnits: .cpuOnly` by default, matching design section 9's "LS-EEND = CPU（公式に CPU 実行
    /// 最速と明記）".
    func initialize() async throws {
        let model = try await LSEENDModel.loadFromHuggingFace(variant: variant, stepSize: stepSize)
        let timelineConfig = Self.makeTimelineConfig(
            frameDurationSeconds: model.metadata.frameDurationSeconds,
            onsetThreshold: onsetThreshold,
            offsetThreshold: offsetThreshold,
            minDurationOnMs: minDurationOnMs,
            minDurationOffMs: minDurationOffMs
        )
        diarizer = try LSEENDDiarizer(model: model, timelineConfig: timelineConfig)
    }

    /// Pure ms → frame-count conversion for `DiarizerTimelineConfig`'s `minFramesOn`/`minFramesOff`,
    /// rounding to the nearest whole frame exactly the way FluidAudio's own seconds accessors do
    /// (`Int(round(seconds / frameDurationSeconds))`, `DiarizerTimeline.swift`). Split out as a `static`
    /// function purely so it is unit-testable without loading a real CoreML model (no network in tests
    /// — `docs/design/13-speaker-diarization.md` section 11).
    ///
    /// Returns `0` (FluidAudio's "no post-processing" value) for a non-positive `ms` or a non-positive
    /// `frameDurationSeconds`; the latter cannot happen with a real model's metadata but must not divide
    /// by zero if it ever did.
    ///
    /// The division is deliberately done in `Float`, not `Double`: `frameDurationSeconds` *is* a
    /// `Float` (it comes from `LSEENDMetadata`), and widening it to `Double` exposes its binary
    /// representation error — e.g. a 0.1 s frame widens to 0.10000000149…, making 250 ms come out as
    /// 2.499999… frames and round *down* to 2 where FluidAudio's own `Float` arithmetic gets a clean
    /// 2.5 and rounds to 3. Staying in `Float` keeps `DiarizerTimelineConfig.minDurationOn` reading
    /// back the duration that was configured.
    static func timelineFrames(ms: Int, frameDurationSeconds: Float) -> Int {
        guard ms > 0, frameDurationSeconds > 0 else {
            return 0
        }
        return Int((Float(ms) / 1000.0 / frameDurationSeconds).rounded())
    }

    /// Builds the `DiarizerTimelineConfig` `initialize()` hands to `LSEENDDiarizer`. `numSpeakers` is
    /// left at the struct's own default because `LSEENDDiarizer.init(model:timelineConfig:)` overwrites
    /// it (and `frameDurationSeconds`) from the model metadata anyway — `frameDurationSeconds` is still
    /// passed here so the frame counts computed alongside it stay self-consistent.
    ///
    /// The onset/offset **padding** frames are deliberately left at `0`: FluidAudio's pass-through
    /// default. Padding widens every turn outward, which is the opposite of what the minimum-duration
    /// gates are here for, and no measurement so far calls for it.
    static func makeTimelineConfig(
        frameDurationSeconds: Float,
        onsetThreshold: Double,
        offsetThreshold: Double,
        minDurationOnMs: Int,
        minDurationOffMs: Int
    ) -> DiarizerTimelineConfig {
        DiarizerTimelineConfig(
            frameDurationSeconds: frameDurationSeconds,
            onsetThreshold: Float(onsetThreshold),
            offsetThreshold: Float(offsetThreshold),
            minFramesOn: timelineFrames(ms: minDurationOnMs, frameDurationSeconds: frameDurationSeconds),
            minFramesOff: timelineFrames(ms: minDurationOffMs, frameDurationSeconds: frameDurationSeconds)
        )
    }

    func addAudio(_ samples: [Float]) async throws {
        guard let diarizer else {
            throw DiarizationBackendError.notInitialized
        }
        try diarizer.addAudio(samples, sourceSampleRate: 16_000)
    }

    func process() async throws -> DiarizerTimelineUpdate? {
        guard let diarizer else {
            throw DiarizationBackendError.notInitialized
        }
        return try diarizer.process()
    }

    /// **Why `finalizeSession()` is treated as terminal** (design section 5.1's open question, "flush
    /// 相当の API の有無" / "LSEENDDiarizer に flush 相当の API があるかはスパイク 2 で確認"): reading
    /// `LSEENDDiarizer.finalizeSession()`'s implementation (FluidAudio `Diarizer/LS-EEND/LSEENDDiarizer.swift`)
    /// shows it calls `session.drainRightContextWithSilence()` (injects silence into the
    /// `LSEENDFeatureProvider`'s ring buffer to push out the model's remaining right-context lookahead)
    /// and then `timeline.finalize()` (folds tentative predictions into finalized ones, marking the
    /// timeline `finalized`). Neither call resets the feature provider's running CMN (cepstral mean
    /// normalization) statistics or its ring-buffer write position, and FluidAudio exposes no public API
    /// to "un-finalize" a session — the only documented resume-after-end path is `processComplete(...)`,
    /// which explicitly calls `resetStreamingState()` (clearing the feature provider entirely) before
    /// replaying audio. Feeding more real audio straight after `finalizeSession()` would therefore bake
    /// that flush's injected silence permanently into the running CMN statistics with no way back, and
    /// no FluidAudio test/doc confirms this is even safe to attempt.
    ///
    /// Rather than depend on unverified internal behavior, this backend/coordinator pair always pairs
    /// `finalizeSession()` with a `reset()` before the next generation starts
    /// (`RealtimeDiarizationCoordinator.beginSegment(startMsOffset:hasSystemAudio:)`) — exactly the
    /// "Paused 跨ぎ品質劣化時のフォールバック" design section 5.1 already sanctions as an acceptable
    /// (re)creation trigger ("区間ごとに意図的に再作成する運用"). Concretely this makes **every** recording
    /// segment boundary (not only window-close/crash-recovery boundaries) a fresh diarizer generation
    /// with its own base offset — the coordinator's `beginSegment` always calls `initialize()` (first
    /// ever segment) or `reset()` (every segment after that), never "keep the same generation across a
    /// pause".
    func finalizeSession() async throws -> DiarizerTimelineUpdate? {
        guard let diarizer else {
            throw DiarizationBackendError.notInitialized
        }
        return try diarizer.finalizeSession()
    }

    func reset() async {
        diarizer?.reset()
    }
}
