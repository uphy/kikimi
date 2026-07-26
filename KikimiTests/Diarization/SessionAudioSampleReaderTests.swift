import AVFoundation
import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `AVAudioFileSampleReader` (`Kikimi/Diarization/SessionAudioSampleReader.swift`),
/// the WAV-reading side of the on-demand voiceprint fallback
/// (`docs/design/13-speaker-diarization.md` section 4.4, "実装時の追記 2026-07-03"). Round-trips
/// through `WavFileWriter` (the same writer `AudioCapture` uses to produce real `system_NNN.wav`
/// files) so these tests exercise the exact on-disk format this reader must handle, rather than a
/// hand-crafted byte fixture.
@Suite("AVAudioFileSampleReader")
struct SessionAudioSampleReaderTests {
    private let sampleRate: Double = 16_000
    private let channels: AVAudioChannelCount = 1
    /// `WavFileWriter` round-trips Float32 through 16-bit PCM (`WavFileWriterTests`'s own precedent);
    /// this is generous enough to absorb that quantization step without being so loose it would miss
    /// a genuine off-by-one/scaling bug.
    private let quantizationTolerance: Float = 0.001

    private func makeTemporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionAudioSampleReaderTests-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("wav")
    }

    /// Writes `values` (already in `[-1, 1]` range) as a mono Float32 WAV file at `fileURL`, waiting
    /// synchronously (`WavFileWriter.close()`) until every byte has actually landed on disk.
    private func writeWav(values: [Float], to fileURL: URL) throws {
        let writer = try WavFileWriter(fileURL: fileURL, sampleRate: sampleRate, channels: channels, headerFlushInterval: 60)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
        buffer.frameLength = AVAudioFrameCount(values.count)
        let channelData = buffer.floatChannelData![0]
        for (index, value) in values.enumerated() {
            channelData[index] = value
        }

        let failures = LockedErrorBox()
        writer.append(buffer) { failures.record($0) }
        writer.close()
        #expect(failures.errors.isEmpty)
    }

    /// A distinctive ramp (not silence, not a single repeated value) so a slicing bug that returns
    /// the wrong offset shows up as a value mismatch, not just a count mismatch.
    private func rampValues(count: Int) -> [Float] {
        (0..<count).map { Float($0) / Float(count) - 0.5 }
    }

    @Test("reading the full range round-trips every sample within Int16 quantization tolerance")
    func readsFullRange() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let values = rampValues(count: 1_000)
        try writeWav(values: values, to: fileURL)

        let reader = AVAudioFileSampleReader()
        let read = try reader.readSamples(fileURL: fileURL, sampleRange: 0..<1_000)

        #expect(read.count == 1_000)
        for (expected, actual) in zip(values, read) {
            #expect(abs(expected - actual) < quantizationTolerance)
        }
    }

    @Test("reading a sub-range in the middle returns exactly that slice, correctly offset")
    func readsMiddleSubRange() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let values = rampValues(count: 1_000)
        try writeWav(values: values, to: fileURL)

        let reader = AVAudioFileSampleReader()
        let read = try reader.readSamples(fileURL: fileURL, sampleRange: 200..<300)

        #expect(read.count == 100)
        for (expected, actual) in zip(values[200..<300], read) {
            #expect(abs(expected - actual) < quantizationTolerance)
        }
    }

    @Test("a range starting at or past the file's end returns an empty array, not an error")
    func rangeStartingPastEndOfFileIsEmpty() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try writeWav(values: rampValues(count: 100), to: fileURL)

        let reader = AVAudioFileSampleReader()
        #expect(try reader.readSamples(fileURL: fileURL, sampleRange: 100..<200).isEmpty)
        #expect(try reader.readSamples(fileURL: fileURL, sampleRange: 500..<600).isEmpty)
    }

    @Test("a range extending past the file's end is clamped to the samples actually available")
    func rangeExtendingPastEndOfFileIsClamped() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let values = rampValues(count: 100)
        try writeWav(values: values, to: fileURL)

        let reader = AVAudioFileSampleReader()
        let read = try reader.readSamples(fileURL: fileURL, sampleRange: 80..<1_000)

        #expect(read.count == 20)
        for (expected, actual) in zip(values[80..<100], read) {
            #expect(abs(expected - actual) < quantizationTolerance)
        }
    }

    @Test("an empty requested range returns an empty array without opening the file")
    func emptyRangeReturnsEmpty() throws {
        let fileURL = makeTemporaryFileURL()
        // Deliberately never created: an empty range must short-circuit before any file access, so
        // this must not throw a file-not-found error.
        let reader = AVAudioFileSampleReader()
        #expect(try reader.readSamples(fileURL: fileURL, sampleRange: 0..<0).isEmpty)
    }
}

/// Thread-safe error recorder mirroring `WavFileWriterTests`' own `FailureRecorder`, duplicated here
/// (rather than made `internal` in that test file) since these are two independent test targets'
/// files that should not need to import each other.
private final class LockedErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var errors: [Error] = []

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(error)
    }
}
