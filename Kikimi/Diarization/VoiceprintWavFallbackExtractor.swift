import Foundation
import OSLog

// MARK: - VoiceprintWavFallbackExtracting (DI seam)

/// Abstraction over `VoiceprintWavFallbackExtractor`'s single meaningful operation
/// (`docs/design/13-speaker-diarization.md` section 4.4, "実装時の追記 2026-07-03"). Mirrors
/// `DiarizationCoordinating`'s role (`MeetingWorkspaceViewModel+Diarization.swift`): `MeetingWorkspace
/// ViewModel` only ever talks to this protocol, so tests inject a fake that returns a deterministic
/// embedding/`nil`/throws without touching a real `AVAudioFile`/WeSpeaker CoreML model.
protocol VoiceprintWavFallbackExtracting: Sendable {
    /// Attempts to extract a WeSpeaker embedding for `slot` on demand from this session's own
    /// `diarization.jsonl` turns and `audio/system_NNN.wav` files.
    ///
    /// - Returns: `nil` when there just isn't enough attributed speech to bother (`slot` has no
    ///   turns, no `RecordingSegment`s exist, or the slot's cumulative turn duration is below
    ///   `diarization.min_enroll_speech_ms`) or every resolved slice's WAV file is missing/empty --
    ///   all expected, silent "don't bother" outcomes the caller should treat exactly like the
    ///   original R2 carve-out ("slot の embedding が null の場合はセッション内の display_name 保存のみ").
    /// - Throws: Only for an actual I/O/extraction failure (`diarization.jsonl` unreadable, WAV
    ///   corrupt, WeSpeaker model load/extraction failure). The caller treats every throw as
    ///   best-effort (kikimi.md 8.5 章 / design section 8): logged and swallowed, never blocking the
    ///   rename UI or recording/STT.
    func extractEmbedding(forSlot slot: String) async throws -> [Float]?
}

extension VoiceprintWavFallbackExtractor: VoiceprintWavFallbackExtracting {}

// MARK: - VoiceprintWavFallbackExtractor

/// Extracts a WeSpeaker voiceprint embedding on demand for a slot whose live capture (`Realtime
/// DiarizationCoordinator+Voiceprint.swift`) never captured one -- either because it was recorded
/// before R2 shipped, or because the slot simply never accumulated `min_enroll_speech_ms` of speech
/// live (the session's own `audio/system_NNN.wav` files are complete and hold everything needed to
/// try again after the fact, kikimi.md 4 章).
///
/// An `actor` (not a plain struct), even though it holds no genuinely mutable state, so every one of
/// its calls -- including `AVAudioFileSampleReader`'s synchronous, blocking disk reads -- runs on this
/// actor's own executor rather than wherever its caller happens to be isolated
/// (`MeetingWorkspaceViewModel+Diarization.swift`'s `scheduleVoiceprintWavFallbackEnrollment(slot:
/// displayName:)` calls this from an unstructured `Task` that would otherwise inherit `@MainActor`
/// isolation from `applyRename(slot:submission:)` -- design section 4.4's "Task 内なので UI は影響なし"
/// note only holds if the blocking I/O itself never actually runs on the main actor).
actor VoiceprintWavFallbackExtractor {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "VoiceprintWavFallbackExtractor")

    private let sessionHandle: SessionHandle
    private let audioReader: any SessionAudioSampleReading
    private let voiceprintExtractor: any VoiceprintEmbeddingExtracting
    private let minEnrollSpeechMs: Int

    /// - Parameters:
    ///   - sessionHandle: This session's sole `diarization.jsonl`/`meta.json` owner
    ///     (`SessionHandle+Diarization.swift`); also used to resolve `audio/system_NNN.wav` paths via
    ///     its `directoryURL`.
    ///   - audioReader: Defaults to `AVAudioFileSampleReader()`. Injectable so tests never touch a
    ///     real WAV file on disk.
    ///   - voiceprintExtractor: Defaults to a real, lazily-loaded `VoiceprintExtractor()` (design
    ///     section 5). Injectable so tests never trigger a real CoreML load/network download.
    ///   - minEnrollSpeechMs: `config.yaml`'s `diarization.min_enroll_speech_ms` (design section 4.4's
    ///     fallback-specific gate; default kept in step with `DiarizationConfig.default`, raised to
    ///     10000ms on 2026-08-01 — design section 7's 追記). The production call site
    ///     (`MeetingWorkspaceViewModel.defaultVoiceprintWavFallbackExtractorFactory`) always passes
    ///     the resolved `AppConfig.shared` value instead of relying on this default.
    init(
        sessionHandle: SessionHandle,
        audioReader: any SessionAudioSampleReading = AVAudioFileSampleReader(),
        voiceprintExtractor: any VoiceprintEmbeddingExtracting = VoiceprintExtractor(),
        minEnrollSpeechMs: Int = 10_000
    ) {
        self.sessionHandle = sessionHandle
        self.audioReader = audioReader
        self.voiceprintExtractor = voiceprintExtractor
        self.minEnrollSpeechMs = minEnrollSpeechMs
    }

    func extractEmbedding(forSlot slot: String) async throws -> [Float]? {
        let turns: [DiarizationTurn]
        do {
            turns = try await sessionHandle.readDiarizationTurns()
        } catch {
            Self.logger.error(
                "Failed to read diarization.jsonl for the WAV voiceprint fallback (slot \(slot, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            throw error
        }

        let recordings = await sessionHandle.meta.recordings
        guard let slices = VoiceprintEnrollmentSampleResolver.resolveSampleSlices(
            turns: turns,
            slot: slot,
            recordings: recordings,
            minEnrollSpeechMs: minEnrollSpeechMs
        ) else {
            Self.logger.info(
                "Slot \(slot, privacy: .public) has no turns, no recording segments, or too little cumulative speech for the WAV voiceprint fallback; skipping extraction."
            )
            return nil
        }

        guard let samples = try EnrollmentAudioSampleReading.readSamples(
            slices: slices,
            sessionHandle: sessionHandle,
            audioReader: audioReader,
            logger: Self.logger,
            logContext: "the WAV voiceprint fallback for slot \(slot)"
        ) else {
            return nil
        }

        return try await voiceprintExtractor.extractEmbedding(from: samples)
    }
}
