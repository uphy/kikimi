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

    /// Polls until the on-disk `data` chunk size reaches `expected`, so a test can wait for a
    /// scheduled header flush *without* pinning the wait to a fixed duration -- the same
    /// poll-don't-sleep pattern the view model/diarization suites use, and for the same reason: a
    /// runner sharing a few cores with ~2,000 parallel tests delays a `DispatchSourceTimer`
    /// arbitrarily. Returns as soon as the condition holds, so the generous ceiling costs a passing
    /// test nothing.
    private func waitForDataChunkSize(
        _ expected: UInt32,
        at url: URL,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? readDataChunkSize(at: url)) == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try readDataChunkSize(at: url) == expected, "the header never reached \(expected) within \(timeout)")
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

    @Test("in-progress header reflects only data flushed so far; close() writes the final total")
    func inProgressHeaderThenFinalHeaderOnClose() async throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // A 2-second period, not a fraction of one: the stale-header assertion below has to happen
        // between two flushes, and the headroom it gets is the whole interval minus the poll's own
        // granularity. The previous 0.3s interval plus a fixed `sleep(interval + 0.4)` failed on CI
        // for exactly this reason -- an overrun sleep landed just before a flush boundary, so the
        // "still stale" read raced the very next flush and saw both chunks.
        let flushInterval: TimeInterval = 2
        let writer = try WavFileWriter(fileURL: fileURL, sampleRate: sampleRate, channels: channels, headerFlushInterval: flushInterval)
        let failures = FailureRecorder()

        // First chunk: 100 frames of mono Int16 == 200 bytes.
        let firstFrameCount: AVAudioFrameCount = 100
        let firstByteCount = UInt32(firstFrameCount) * UInt32(channels) * UInt32(MemoryLayout<Int16>.size)
        writer.append(makeBuffer(frameCount: firstFrameCount)) { failures.record($0) }

        // Wait for the first scheduled header flush, rather than for a fixed span assumed to
        // contain it, so the in-progress header on disk provably reflects the first chunk.
        try await waitForDataChunkSize(firstByteCount, at: fileURL)

        // Second chunk, appended immediately after that flush was observed -- which puts the next
        // one a full `flushInterval` away, so the read below cannot straddle it. The on-disk header
        // must still be stale (first chunk only) until the writer is explicitly closed.
        let secondFrameCount: AVAudioFrameCount = 50
        let secondByteCount = UInt32(secondFrameCount) * UInt32(channels) * UInt32(MemoryLayout<Int16>.size)
        writer.append(makeBuffer(frameCount: secondFrameCount)) { failures.record($0) }
        try await Task.sleep(for: .milliseconds(50)) // long enough to be enqueued, far short of the next flush

        let staleDataSize = try readDataChunkSize(at: fileURL)
        #expect(staleDataSize == firstByteCount)

        writer.close()

        let finalByteCount = firstByteCount + secondByteCount
        let finalDataSize = try readDataChunkSize(at: fileURL)
        #expect(finalDataSize == finalByteCount)

        let finalFileData = try Data(contentsOf: fileURL)
        #expect(finalFileData.count == 44 + Int(finalByteCount))

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
