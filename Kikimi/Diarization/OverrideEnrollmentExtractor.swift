import Foundation
import OSLog

// MARK: - OverrideEnrollmentExtracting (DI seam)

/// Abstraction over `OverrideEnrollmentExtractor`'s single meaningful operation
/// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 5.4's stage 2). Mirrors
/// `VoiceprintWavFallbackExtracting`'s test-seam role (`VoiceprintWavFallbackExtractor.swift`):
/// `MeetingWorkspaceViewModel` only ever talks to this protocol (via
/// `+OverrideEnrollment.swift`'s `overrideEnrollmentExtractorFactory`), so tests inject a fake that
/// returns a deterministic embedding/`nil`/throws without touching a real `AVAudioFile`/WeSpeaker
/// CoreML model.
protocol OverrideEnrollmentExtracting: Sendable {
    /// Extracts one WeSpeaker embedding from `slices` -- sample ranges already resolved by stage 1
    /// (`OverrideEnrollmentSampleResolver.resolveSampleSlices(...)`, run synchronously against
    /// `diarization.jsonl`/`speaker_assignments.json`/`transcriptRows` before this stage ever starts).
    /// Unlike `VoiceprintWavFallbackExtracting.extractEmbedding(forSlot:)`, this type does no turn
    /// resolution of its own -- it only ever reads exactly the WAV ranges it is handed.
    ///
    /// - Returns: `nil` when every resolved slice's WAV file turns out to be missing/empty on disk (a
    ///   session moved/partially deleted between stage 1 and stage 2 running, or `slices` is empty) --
    ///   an expected, silent "don't bother" outcome the caller treats exactly like `Voiceprint
    ///   WavFallbackExtracting`'s own `nil` case.
    /// - Throws: Only for an actual I/O/extraction failure (WAV corrupt, WeSpeaker model load/extraction
    ///   failure). The caller treats every throw as best-effort (kikimi.md 8.5 章 / design section 8):
    ///   logged and swallowed, **never** falling back to a slot-derived sample (design section 5.4's
    ///   explicit "段階 2 の抽出が失敗した場合も slot 由来へはフォールバックしない").
    func extractEmbedding(slices: [EnrollmentSampleSlice]) async throws -> [Float]?
}

extension OverrideEnrollmentExtractor: OverrideEnrollmentExtracting {}

// MARK: - OverrideEnrollmentExtractor

/// Reads the WAV samples stage 1 already resolved for one enrollment identity's override-aggregate
/// sample (`docs/design/20-voiceprint-misassignment-mitigation.md` section 5.4's stage 2) and extracts
/// one WeSpeaker embedding from them. An `actor` (not a plain struct), same rationale as `Voiceprint
/// WavFallbackExtractor`: every call -- including `AVAudioFileSampleReader`'s synchronous, blocking
/// disk reads -- must run on this actor's own executor rather than wherever its caller happens to be
/// isolated (`MeetingWorkspaceViewModel+OverrideEnrollment.swift`'s `scheduleOverrideEnrollment(...)`
/// calls this from an unstructured `Task` that would otherwise inherit `@MainActor` isolation).
///
/// Deliberately **not** a copy of `VoiceprintWavFallbackExtractor`'s slot-turn resolution: stage 1
/// (`OverrideEnrollmentSampleResolver.resolveSampleSlices(...)`) already did that synchronously, using
/// data (`transcriptRows`, `diarizationTurns`, `SpeakerAssignments`) this actor has no reason to read a
/// second time. This type's whole job is steps 1 of design section 5.4's stage 2: read the resolved
/// `EnrollmentSampleSlice`s from `audio/system_NNN.wav` and hand the concatenated samples to
/// `VoiceprintExtractor`.
actor OverrideEnrollmentExtractor {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "OverrideEnrollmentExtractor")

    private let sessionHandle: SessionHandle
    private let audioReader: any SessionAudioSampleReading
    private let voiceprintExtractor: any VoiceprintEmbeddingExtracting

    /// - Parameters:
    ///   - sessionHandle: Used only to resolve `audio/system_NNN.wav` paths via its `directoryURL`
    ///     (`SessionHandle`'s `let`, safely readable from any isolation context).
    ///   - audioReader: Defaults to `AVAudioFileSampleReader()`. Injectable so tests never touch a real
    ///     WAV file on disk.
    ///   - voiceprintExtractor: Defaults to a real, lazily-loaded `VoiceprintExtractor()` (design
    ///     section 5). Injectable so tests never trigger a real CoreML load/network download.
    init(
        sessionHandle: SessionHandle,
        audioReader: any SessionAudioSampleReading = AVAudioFileSampleReader(),
        voiceprintExtractor: any VoiceprintEmbeddingExtracting = VoiceprintExtractor()
    ) {
        self.sessionHandle = sessionHandle
        self.audioReader = audioReader
        self.voiceprintExtractor = voiceprintExtractor
    }

    func extractEmbedding(slices: [EnrollmentSampleSlice]) async throws -> [Float]? {
        guard !slices.isEmpty else {
            return nil
        }

        guard let samples = try EnrollmentAudioSampleReading.readSamples(
            slices: slices,
            sessionHandle: sessionHandle,
            audioReader: audioReader,
            logger: Self.logger,
            logContext: "the override-aggregate enrollment extraction"
        ) else {
            return nil
        }

        return try await voiceprintExtractor.extractEmbedding(from: samples)
    }
}
