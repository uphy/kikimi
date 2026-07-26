import Foundation
import OSLog

// MARK: - EnrollmentAudioSampleReading

/// Shared WAV-slice-to-samples reader for both R2 voiceprint enrollment extractors
/// (`OverrideEnrollmentExtractor.swift` / `VoiceprintWavFallbackExtractor.swift`,
/// `docs/design/13-speaker-diarization.md` section 4.4 / `docs/design/20-voiceprint-misassignment
/// -mitigation.md` section 5.4's stage 2): resolves each `EnrollmentSampleSlice`'s recording index to
/// its own `audio/system_NNN.wav` file (kikimi.md 4 章), reads the requested sample range from it via
/// the caller's own `SessionAudioSampleReading`, and concatenates every slice's samples in chronological
/// order. A missing WAV file for one slice is a warning-logged skip, not a failure -- the caller may
/// still have enough audio from its other slices to extract from.
enum EnrollmentAudioSampleReading {
    /// - Parameters:
    ///   - slices: Already-resolved sample ranges (stage 1, run by the caller before this is invoked).
    ///   - sessionHandle: Used only to resolve `audio/`'s directory URL (`SessionHandle.directoryURL`,
    ///     a `let`, safely readable from any isolation context).
    ///   - audioReader: The caller's own `SessionAudioSampleReading` (real or fake) -- neither this
    ///     type nor its callers assume a specific implementation.
    ///   - logger: The caller's own `Logger` instance, so the warning/info logs below still show up
    ///     under that caller's own subsystem/category rather than a third, shared one.
    ///   - logContext: A short caller-supplied noun phrase describing what this read is for (e.g.
    ///     `"the override-aggregate enrollment extraction"` / `"slot \(slot)'s WAV voiceprint
    ///     fallback"`), embedded in both log messages below so they still read naturally despite being
    ///     emitted from shared code.
    /// - Returns: The concatenated samples across every readable slice, or `nil` if every candidate
    ///   `system_NNN.wav` was missing or yielded no samples (an info-logged "don't bother extracting"
    ///   outcome, matching both callers' pre-refactor behavior).
    /// - Throws: Whatever `audioReader.readSamples(fileURL:sampleRange:)` throws for a slice whose file
    ///   does exist on disk (corrupt WAV, I/O failure) -- propagated, never swallowed.
    static func readSamples(
        slices: [EnrollmentSampleSlice],
        sessionHandle: SessionHandle,
        audioReader: any SessionAudioSampleReading,
        logger: Logger,
        logContext: String
    ) throws -> [Float]? {
        let audioDirectory = sessionHandle.directoryURL.appendingPathComponent("audio", isDirectory: true)
        var samples: [Float] = []
        samples.reserveCapacity(VoiceprintExtractor.maxSampleCount)
        for slice in slices {
            let fileURL = audioDirectory.appendingPathComponent(AudioCapture.systemFileName(recordingIndex: slice.recordingIndex))
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                logger.warning(
                    "system_\(slice.recordingIndex, privacy: .public).wav is missing; skipping this slice of \(logContext, privacy: .public)."
                )
                continue
            }
            let read = try audioReader.readSamples(fileURL: fileURL, sampleRange: slice.sampleRange)
            samples.append(contentsOf: read)
        }

        guard !samples.isEmpty else {
            logger.info(
                "No audio samples were readable for \(logContext, privacy: .public) (every candidate system_NNN.wav was missing or empty); skipping extraction."
            )
            return nil
        }
        return samples
    }
}
