import AVFoundation
import Foundation

// MARK: - SessionAudioSampleReading (DI seam)

/// Abstraction over reading a slice of 16 kHz mono Float32 samples out of a session's own
/// `audio/system_NNN.wav` file (`docs/design/13-speaker-diarization.md` section 4.4's on-demand WAV
/// voiceprint fallback, "実装時の追記 2026-07-03"). Mirrors `VoiceprintEmbeddingExtracting`'s test-seam
/// role (`VoiceprintExtractor.swift`): `VoiceprintWavFallbackExtractor` only ever talks to this
/// protocol, so unit tests can inject canned samples without touching a real file on disk.
protocol SessionAudioSampleReading: Sendable {
    /// Reads `sampleRange` (0-based frame offsets into `fileURL`, at 16 kHz) as mono Float32 samples.
    /// Clamps to the file's actual frame count rather than throwing: a `sampleRange` that runs past
    /// the end of the file (a crash-truncated WAV, or a turn whose nominal duration slightly overruns
    /// what actually got written) degrades to "however many samples are really there", matching this
    /// whole feature's best-effort contract (design section 8) -- it is the caller's job to treat a
    /// shorter-than-requested (or empty) result as "use what we got", not a failure.
    ///
    /// - Returns: An empty array (not an error) if `sampleRange` starts at or past the file's end.
    func readSamples(fileURL: URL, sampleRange: Range<Int>) throws -> [Float]
}

// MARK: - SessionAudioSampleReaderError

enum SessionAudioSampleReaderError: LocalizedError, Equatable {
    case unableToAllocateBuffer
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unableToAllocateBuffer:
            return "Failed to allocate a PCM buffer to read WAV samples into."
        case .unsupportedFormat:
            return "The WAV file's processing format has no float channel data to read."
        }
    }
}

// MARK: - AVAudioFileSampleReader

/// Production `SessionAudioSampleReading` backed by `AVAudioFile`, the same WAV-decoding mechanism
/// `TestFileAudioSource` already uses for the `KIKIMI_TEST_INPUT` dummy-audio path
/// (`Kikimi/AudioCapture/TestFileAudioSource.swift`) -- deliberately reused here instead of a
/// hand-rolled `fmt `/`data` chunk parser: `AVAudioFile.processingFormat` already gives back exactly
/// the Float32, non-interleaved, 16 kHz mono samples this whole pipeline works in everywhere else
/// (`AudioCapture`'s captured buffers, `WavFileWriter`'s input side, `RealtimeDiarizationCoordinator
/// .feed(samples:)`), so there is no separate Int16 -> Float32 normalization step to get right or test
/// independently -- `AVAudioFile`'s own internal conversion already matches this codebase's existing,
/// already-exercised WAV-reading precedent.
struct AVAudioFileSampleReader: SessionAudioSampleReading {
    func readSamples(fileURL: URL, sampleRange: Range<Int>) throws -> [Float] {
        guard sampleRange.lowerBound >= 0, !sampleRange.isEmpty else {
            return []
        }

        let file = try AVAudioFile(forReading: fileURL)
        let totalFrameCount = Int(file.length)
        guard sampleRange.lowerBound < totalFrameCount else {
            return []
        }

        let clampedUpperBound = min(sampleRange.upperBound, totalFrameCount)
        let frameCountToRead = clampedUpperBound - sampleRange.lowerBound
        guard frameCountToRead > 0 else {
            return []
        }

        file.framePosition = AVAudioFramePosition(sampleRange.lowerBound)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCountToRead)) else {
            throw SessionAudioSampleReaderError.unableToAllocateBuffer
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frameCountToRead))

        guard let channelData = buffer.floatChannelData else {
            throw SessionAudioSampleReaderError.unsupportedFormat
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}
