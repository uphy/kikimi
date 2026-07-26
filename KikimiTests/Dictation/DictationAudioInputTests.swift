import AVFoundation
import Foundation
import Testing

@testable import Kikimi

/// Covers `docs/design/29-dictation-history.md` §4.2 (DH3/DH6): `DictationAudioInput` tees mic
/// buffers to a `WavFileWriter` when `recordingURL` is supplied, and a failed writer never blocks
/// the STT path.
///
/// These tests deliberately never call `DictationAudioInput.start(samplesHandler:)`: that method
/// calls through to `MicrophoneSource.start(bufferHandler:)`, which can synchronously block the
/// calling thread on the system microphone-permission prompt (`MicrophoneSource.swift`'s doc
/// comment on `start`) -- unsafe to run inside a test process. Instead they drive the two
/// `internal` seams `start()` is built from (`openWavWriterIfNeeded()` / `handleCapturedBuffer(_:samplesHandler:)`)
/// directly, matching the "testable seams" pattern already used elsewhere in this codebase
/// (e.g. `AudioCapture.elapsed(from:recordingStartHostTime:)`, `DictationHistoryPruning.entriesToDelete`).
@Suite("DictationAudioInput")
struct DictationAudioInputTests {
    private let sampleRate: Double = 16_000
    private let channels: AVAudioChannelCount = 1

    /// Builds a Float32 standard-format buffer -- exactly the format `MicrophoneSource` hands to
    /// `DictationAudioInput`'s tap closure (`DictationAudioInput.swift` doc comments) -- filled
    /// with `frameCount` frames of silence. Sample values don't matter for these tests, only counts.
    private func makeBuffer(frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        return buffer
    }

    /// Reads the WAV header fields this test cares about directly off disk, bypassing
    /// `WavFileWriter`/`WavHeader` entirely (mirrors `WavFileWriterTests.readDataChunkSize`).
    private func readHeader(at url: URL) throws -> (channels: UInt16, sampleRate: UInt32, bitsPerSample: UInt16) {
        let fileData = try Data(contentsOf: url)
        func readUInt16(at offset: Int) -> UInt16 {
            let bytes = [UInt8](fileData[offset..<(offset + 2)])
            return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        }
        func readUInt32(at offset: Int) -> UInt32 {
            let bytes = [UInt8](fileData[offset..<(offset + 4)])
            return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        }
        return (channels: readUInt16(at: 22), sampleRate: readUInt32(at: 24), bitsPerSample: readUInt16(at: 34))
    }

    /// Reads the 4-byte little-endian `data` chunk size (bytes 40..<44) directly off disk,
    /// mirroring `WavFileWriterTests.readDataChunkSize` -- used here to confirm the *tee* actually
    /// lands real sample bytes on disk (design 29 §4.2 DH3), not just a well-formed empty header.
    private func readDataChunkSize(at url: URL) throws -> UInt32 {
        let fileData = try Data(contentsOf: url)
        let bytes = [UInt8](fileData[40..<44])
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationAudioInputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("recordingURL produces a 16kHz mono 16-bit WAV header")
    func recordingURLProducesValidWavHeader() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingURL = directory.appendingPathComponent("audio.wav", isDirectory: false)

        let input = DictationAudioInput(deviceUID: nil, recordingURL: recordingURL)
        input.openWavWriterIfNeeded()
        input.stop() // closes the writer, finalizing the header

        let header = try readHeader(at: recordingURL)
        #expect(header.channels == 1)
        #expect(header.sampleRate == 16_000)
        #expect(header.bitsPerSample == 16)
    }

    @Test("recordingURL == nil never creates a WAV writer or file")
    func noRecordingURLMeansNoFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = DictationAudioInput(deviceUID: nil, recordingURL: nil)
        input.openWavWriterIfNeeded()
        input.stop()

        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(contents.isEmpty)
    }

    @Test("a writer init failure (missing parent directory) never affects samplesHandler")
    func writerInitFailureDoesNotAffectSamplesHandler() throws {
        // No `createDirectory` call: this parent is deliberately never created, so
        // `WavFileWriter.init` (which does not create its parent, by design) throws.
        let missingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationAudioInputTests-missing-\(UUID().uuidString)", isDirectory: true)
        let recordingURL = missingParent.appendingPathComponent("audio.wav", isDirectory: false)

        let input = DictationAudioInput(deviceUID: nil, recordingURL: recordingURL)
        input.openWavWriterIfNeeded() // fails internally; must not throw out of this call

        var receivedSampleCounts: [Int] = []
        let frameCount: AVAudioFrameCount = 160 // 10ms at 16kHz
        input.handleCapturedBuffer(makeBuffer(frameCount: frameCount)) { samples in
            receivedSampleCounts.append(samples.count)
        }

        #expect(receivedSampleCounts == [Int(frameCount)])
        #expect(input.recordedSampleCount == Int(frameCount))
        #expect(!FileManager.default.fileExists(atPath: recordingURL.path))

        input.stop() // must be a no-op, not a crash, given no writer was ever opened
    }

    @Test("handleCapturedBuffer accumulates recordedSampleCount across multiple buffers")
    func recordedSampleCountAccumulatesAcrossBuffers() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingURL = directory.appendingPathComponent("audio.wav", isDirectory: false)

        let input = DictationAudioInput(deviceUID: nil, recordingURL: recordingURL)
        input.openWavWriterIfNeeded()

        var totalSamplesDelivered = 0
        let firstFrameCount: AVAudioFrameCount = 160
        let secondFrameCount: AVAudioFrameCount = 320
        input.handleCapturedBuffer(makeBuffer(frameCount: firstFrameCount)) { totalSamplesDelivered += $0.count }
        input.handleCapturedBuffer(makeBuffer(frameCount: secondFrameCount)) { totalSamplesDelivered += $0.count }
        input.stop()

        #expect(totalSamplesDelivered == Int(firstFrameCount + secondFrameCount))
        #expect(input.recordedSampleCount == Int(firstFrameCount + secondFrameCount))
    }

    @Test("recordingURL == nil (base dictation flow, DH1) forwards samples with no writer and no disk I/O at all")
    func noRecordingURLStillForwardsSamplesWithoutTouchingDisk() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // No `openWavWriterIfNeeded()`/`stop()` call needed to prove this: `recordingURL == nil`
        // means `handleCapturedBuffer` never has a `wavWriter` to tee to in the first place, since
        // `openWavWriterIfNeeded` is a no-op whenever `recordingURL == nil` (design 29 §4.2 DH1).
        let input = DictationAudioInput(deviceUID: nil, recordingURL: nil)
        input.openWavWriterIfNeeded()

        var receivedSampleCounts: [Int] = []
        let firstFrameCount: AVAudioFrameCount = 160
        let secondFrameCount: AVAudioFrameCount = 240
        input.handleCapturedBuffer(makeBuffer(frameCount: firstFrameCount)) { receivedSampleCounts.append($0.count) }
        input.handleCapturedBuffer(makeBuffer(frameCount: secondFrameCount)) { receivedSampleCounts.append($0.count) }
        input.stop()

        #expect(receivedSampleCounts == [Int(firstFrameCount), Int(secondFrameCount)])
        #expect(input.recordedSampleCount == Int(firstFrameCount + secondFrameCount))
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(contents.isEmpty)
    }

    @Test("accumulateSamples: true keeps every delivered sample in order for the batch re-decode (design 31 TP4)")
    func accumulateSamplesKeepsDeliveredSamples() {
        let input = DictationAudioInput(deviceUID: nil, recordingURL: nil, accumulateSamples: true)
        input.openWavWriterIfNeeded()

        let firstFrameCount: AVAudioFrameCount = 160
        let secondFrameCount: AVAudioFrameCount = 320
        input.handleCapturedBuffer(makeBuffer(frameCount: firstFrameCount)) { _ in }
        input.handleCapturedBuffer(makeBuffer(frameCount: secondFrameCount)) { _ in }
        input.stop()

        #expect(input.recordedSamples.count == Int(firstFrameCount + secondFrameCount))
        #expect(input.recordedSampleCount == input.recordedSamples.count)
    }

    @Test("accumulateSamples: false (two-pass decode off) keeps recordedSamples empty, counter unaffected")
    func accumulateSamplesOffKeepsBufferEmpty() {
        let input = DictationAudioInput(deviceUID: nil, recordingURL: nil, accumulateSamples: false)
        input.openWavWriterIfNeeded()

        let frameCount: AVAudioFrameCount = 160
        input.handleCapturedBuffer(makeBuffer(frameCount: frameCount)) { _ in }
        input.stop()

        #expect(input.recordedSamples.isEmpty)
        #expect(input.recordedSampleCount == Int(frameCount))
    }

    @Test("attachHistoryRecording opens a writer after capture already started (word-drop fix 3a), tee-ing only what arrives afterward")
    func attachHistoryRecordingOpensWriterMidCapture() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingURL = directory.appendingPathComponent("audio.wav", isDirectory: false)

        // No `recordingURL` at construction time -- mirrors `handleHotkeyDown()`'s 3a ordering,
        // where the mic (and this type) starts before `beginHistoryEntryIfNeeded`'s await resolves.
        let input = DictationAudioInput(deviceUID: nil, recordingURL: nil)
        input.openWavWriterIfNeeded() // no-op: recordingURL == nil

        var receivedSampleCounts: [Int] = []
        let beforeAttachFrameCount: AVAudioFrameCount = 160
        input.handleCapturedBuffer(makeBuffer(frameCount: beforeAttachFrameCount)) { receivedSampleCounts.append($0.count) }

        // The history entry resolves and attaches the writer mid-capture.
        input.attachHistoryRecording(url: recordingURL)

        let afterAttachFrameCount: AVAudioFrameCount = 320
        input.handleCapturedBuffer(makeBuffer(frameCount: afterAttachFrameCount)) { receivedSampleCounts.append($0.count) }
        input.stop()

        // samplesHandler (the STT path) is unaffected either way -- both buffers reach it.
        #expect(receivedSampleCounts == [Int(beforeAttachFrameCount), Int(afterAttachFrameCount)])
        #expect(input.recordedSampleCount == Int(beforeAttachFrameCount + afterAttachFrameCount))
        // Only the buffer delivered after `attachHistoryRecording` lands on disk -- the pre-attach
        // buffer was already gone by the time a writer existed to tee it to.
        let expectedByteCount = UInt32(afterAttachFrameCount) * 2
        #expect(try readDataChunkSize(at: recordingURL) == expectedByteCount)
    }

    @Test("the tee writes real sample bytes to disk, not just an empty header (DH3)")
    func teeWritesActualSampleDataMatchingRecordedSampleCount() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingURL = directory.appendingPathComponent("audio.wav", isDirectory: false)

        let input = DictationAudioInput(deviceUID: nil, recordingURL: recordingURL)
        input.openWavWriterIfNeeded()

        let firstFrameCount: AVAudioFrameCount = 160
        let secondFrameCount: AVAudioFrameCount = 320
        input.handleCapturedBuffer(makeBuffer(frameCount: firstFrameCount)) { _ in }
        input.handleCapturedBuffer(makeBuffer(frameCount: secondFrameCount)) { _ in }
        input.stop() // waits for in-flight appends and rewrites the final header (WavFileWriter.close)

        // 16-bit mono PCM: 2 bytes per sample. Confirms `handleCapturedBuffer` actually tees each
        // buffer's audio (not just its count) to `wavWriter` before `extractSamples`.
        let expectedByteCount = UInt32(firstFrameCount + secondFrameCount) * 2
        #expect(try readDataChunkSize(at: recordingURL) == expectedByteCount)
        let fileData = try Data(contentsOf: recordingURL)
        #expect(fileData.count == 44 + Int(expectedByteCount))
        #expect(input.recordedSampleCount == Int(firstFrameCount + secondFrameCount))
    }
}
