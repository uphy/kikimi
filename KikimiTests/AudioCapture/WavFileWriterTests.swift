import AVFoundation
import Foundation
import Testing

@testable import Kikimi

/// Thread-safe recorder for the `onFailure` callback passed to `WavFileWriter.append`.
/// Appends in these tests are all expected to succeed, so `errors` should stay empty; the
/// recorder exists so a regression (an unexpected failure) shows up as a test failure rather
/// than being silently swallowed.
private final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(error)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return errors.count
    }
}

@Suite("WavFileWriter")
struct WavFileWriterTests {
    private let sampleRate: Double = 16_000
    private let channels: AVAudioChannelCount = 1

    /// Builds a Float32 standard-format buffer (matching what `AudioCapture` hands to `append`)
    /// filled with `frameCount` frames of silence. The actual sample values don't matter for these
    /// tests, only the resulting byte counts.
    private func makeBuffer(frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        return buffer
    }

    /// Reads the 4-byte little-endian `data` chunk size (bytes 40..<44) directly from a WAV file
    /// on disk, bypassing `WavFileWriter` entirely, to independently verify what actually landed
    /// on disk.
    private func readDataChunkSize(at url: URL) throws -> UInt32 {
        let fileData = try Data(contentsOf: url)
        let bytes = [UInt8](fileData[40..<44])
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    private func makeTemporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WavFileWriterTests-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("wav")
    }

    @Test("init creates the file with a 44-byte placeholder header of size 0")
    func initWritesPlaceholderHeader() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let writer = try WavFileWriter(fileURL: fileURL, sampleRate: sampleRate, channels: channels, headerFlushInterval: 60)
        defer { writer.close() }

        let fileData = try Data(contentsOf: fileURL)
        #expect(fileData.count == 44)
        #expect(try readDataChunkSize(at: fileURL) == 0)
    }

    @Test("the periodic timer rewrites the in-progress header to cover the data appended so far")
    func periodicTimerFlushesInProgressHeader() async throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let flushInterval: TimeInterval = 0.1
        let writer = try WavFileWriter(fileURL: fileURL, sampleRate: sampleRate, channels: channels, headerFlushInterval: flushInterval)
        let failures = FailureRecorder()

        // 100 frames of mono Int16 == 200 bytes.
        let frameCount: AVAudioFrameCount = 100
        let byteCount = UInt32(frameCount) * UInt32(channels) * UInt32(MemoryLayout<Int16>.size)
        writer.append(makeBuffer(frameCount: frameCount)) { failures.record($0) }

        // Polls for the flush rather than sleeping a fixed multiple of the interval: this waits
        // *for* an event, so a slow runner only makes it take longer, never fail. A fixed sleep
        // would also have to be long enough to cover a late timer, which is the same wait with a
        // hard failure attached.
        var flushed: UInt32 = 0
        for _ in 0..<100 {
            flushed = try readDataChunkSize(at: fileURL)
            if flushed == byteCount { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(flushed == byteCount)

        writer.close()
        #expect(failures.count == 0)
    }

    @Test("the header is not rewritten between flushes; close() writes the final total")
    func staleHeaderUntilCloseWritesFinalTotal() async throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // A 60s interval means no periodic flush can land inside this test. Asserting the *absence*
        // of a flush against a live timer is a race the CI runner loses: the previous version slept
        // past one flush and then assumed the next one was still 200ms away, which stopped holding
        // as soon as `Task.sleep` overshot on a loaded machine.
        let writer = try WavFileWriter(fileURL: fileURL, sampleRate: sampleRate, channels: channels, headerFlushInterval: 60)
        let failures = FailureRecorder()

        let firstFrameCount: AVAudioFrameCount = 100
        let firstByteCount = UInt32(firstFrameCount) * UInt32(channels) * UInt32(MemoryLayout<Int16>.size)
        writer.append(makeBuffer(frameCount: firstFrameCount)) { failures.record($0) }

        let secondFrameCount: AVAudioFrameCount = 50
        let secondByteCount = UInt32(secondFrameCount) * UInt32(channels) * UInt32(MemoryLayout<Int16>.size)
        writer.append(makeBuffer(frameCount: secondFrameCount)) { failures.record($0) }

        // Long enough for both appends to have been drained by the writer queue -- the point is
        // that the sample data lands on disk while the header still reports the placeholder 0.
        try await Task.sleep(nanoseconds: 200_000_000)

        let finalByteCount = firstByteCount + secondByteCount
        #expect(try readDataChunkSize(at: fileURL) == 0)
        #expect(try Data(contentsOf: fileURL).count == 44 + Int(finalByteCount))

        writer.close()

        #expect(try readDataChunkSize(at: fileURL) == finalByteCount)
        #expect(try Data(contentsOf: fileURL).count == 44 + Int(finalByteCount))

        #expect(failures.count == 0)
    }

    @Test("double close() is harmless and does not corrupt the final header")
    func doubleCloseIsHarmless() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let writer = try WavFileWriter(fileURL: fileURL, sampleRate: sampleRate, channels: channels, headerFlushInterval: 60)
        let failures = FailureRecorder()

        let frameCount: AVAudioFrameCount = 80
        let byteCount = UInt32(frameCount) * UInt32(channels) * UInt32(MemoryLayout<Int16>.size)
        writer.append(makeBuffer(frameCount: frameCount)) { failures.record($0) }

        writer.close()
        writer.close() // must be a harmless no-op

        #expect(try readDataChunkSize(at: fileURL) == byteCount)
        let fileData = try Data(contentsOf: fileURL)
        #expect(fileData.count == 44 + Int(byteCount))
        #expect(failures.count == 0)
    }

    @Test("append after close() is silently ignored")
    func appendAfterCloseIsIgnored() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let writer = try WavFileWriter(fileURL: fileURL, sampleRate: sampleRate, channels: channels, headerFlushInterval: 60)
        let failures = FailureRecorder()

        let frameCount: AVAudioFrameCount = 40
        let byteCount = UInt32(frameCount) * UInt32(channels) * UInt32(MemoryLayout<Int16>.size)
        writer.append(makeBuffer(frameCount: frameCount)) { failures.record($0) }
        writer.close()

        // Posted after close(); should be dropped without touching the (already-closed) file handle.
        writer.append(makeBuffer(frameCount: 40)) { failures.record($0) }

        #expect(try readDataChunkSize(at: fileURL) == byteCount)
        #expect(failures.count == 0)
    }
}
