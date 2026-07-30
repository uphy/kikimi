import AVFoundation
import Foundation
import Testing

@testable import Kikimi

@Suite("TestFileAudioSource")
struct TestFileAudioSourceTests {
    @Test("delivers chunks of the configured size and loops back at end of file")
    func deliversAndLoops() async throws {
        let fileURL = try Self.makeWavFixture(totalFrames: 2_500, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let collector = ChunkCollector()
        let source = TestFileAudioSource(fileURL: fileURL, chunkFrameCount: 1_000, tickIntervalOverride: 0.01)
        defer { source.stop() }

        try source.start { buffer, _ in
            collector.record(Int(buffer.frameLength))
        }

        // 2_500 frames / 1_000-frame chunks => one loop is [1000, 1000, 500]. Poll until two full
        // loops have been delivered rather than sleeping for a span assumed to contain them: the
        // source ticks on a timer, and a loaded machine delays ticks arbitrarily.
        try await waitUntil("two full loops of chunks to arrive") { collector.counts.count >= 6 }
        source.stop()

        let counts = collector.counts
        #expect(counts.count >= 6)
        #expect(Array(counts.prefix(3)) == [1_000, 1_000, 500])
        #expect(Array(counts[3..<6]) == [1_000, 1_000, 500])
    }

    @Test("stop() halts further delivery")
    func stopHaltsDelivery() async throws {
        let fileURL = try Self.makeWavFixture(totalFrames: 1_000, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let collector = ChunkCollector()
        let source = TestFileAudioSource(fileURL: fileURL, chunkFrameCount: 1_000, tickIntervalOverride: 0.01)

        try source.start { buffer, _ in
            collector.record(Int(buffer.frameLength))
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        source.stop()
        let countAfterStop = collector.counts.count

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(collector.counts.count == countAfterStop)
    }

    @Test("delivered buffers carry a monotonically increasing host time")
    func deliversIncreasingHostTime() async throws {
        let fileURL = try Self.makeWavFixture(totalFrames: 1_000, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let collector = TimeCollector()
        let source = TestFileAudioSource(fileURL: fileURL, chunkFrameCount: 500, tickIntervalOverride: 0.01)
        defer { source.stop() }

        try source.start { _, time in
            collector.record(time.hostTime)
        }

        try await Task.sleep(nanoseconds: 60_000_000)
        source.stop()

        let times = collector.times
        #expect(times.count >= 2)
        #expect(times == times.sorted())
    }

    @Test("start() throws .fileUnreadable when the file does not exist")
    func throwsOnMissingFile() {
        let source = TestFileAudioSource(fileURL: URL(fileURLWithPath: "/nonexistent/path/does-not-exist.wav"))

        #expect(throws: TestFileAudioSourceError.self) {
            try source.start { _, _ in }
        }
    }

    @Test("start() throws .alreadyRunning on double start")
    func throwsOnDoubleStart() throws {
        let fileURL = try Self.makeWavFixture(totalFrames: 1_000, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let source = TestFileAudioSource(fileURL: fileURL, chunkFrameCount: 1_000, tickIntervalOverride: 1)
        defer { source.stop() }

        try source.start { _, _ in }

        #expect(throws: TestFileAudioSourceError.alreadyRunning) {
            try source.start { _, _ in }
        }
    }

    @Test("stop() before start() is a harmless no-op")
    func stopWithoutStartIsNoop() {
        let source = TestFileAudioSource(fileURL: URL(fileURLWithPath: "/nonexistent.wav"))
        source.stop()
        source.stop()
    }

    @Test("start() succeeds again after stop()")
    func restartAfterStop() throws {
        let fileURL = try Self.makeWavFixture(totalFrames: 1_000, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let source = TestFileAudioSource(fileURL: fileURL, chunkFrameCount: 1_000, tickIntervalOverride: 1)
        try source.start { _, _ in }
        source.stop()

        try source.start { _, _ in }
        source.stop()
    }

    private static func makeWavFixture(totalFrames: Int, sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestFileAudioSourceTests-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            struct FormatCreationFailed: Error {}
            throw FormatCreationFailed()
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            struct BufferAllocationFailed: Error {}
            throw BufferAllocationFailed()
        }
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<totalFrames {
                channel[i] = Float(i % 100) / 100.0
            }
        }
        try file.write(from: buffer)
        return url
    }
}

/// Thread-safe collector for frame counts delivered from `TestFileAudioSource`'s internal queue.
private final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frameCounts: [Int] = []

    func record(_ count: Int) {
        lock.lock()
        frameCounts.append(count)
        lock.unlock()
    }

    var counts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return frameCounts
    }
}

/// Thread-safe collector for host times delivered from `TestFileAudioSource`'s internal queue.
private final class TimeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var hostTimes: [UInt64] = []

    func record(_ hostTime: UInt64) {
        lock.lock()
        hostTimes.append(hostTime)
        lock.unlock()
    }

    var times: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return hostTimes
    }
}
