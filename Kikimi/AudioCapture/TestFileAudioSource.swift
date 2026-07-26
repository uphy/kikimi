import AVFoundation
import Darwin
import Foundation
import OSLog

/// Errors produced by `TestFileAudioSource`.
enum TestFileAudioSourceError: LocalizedError, Equatable {
    case alreadyRunning
    case fileUnreadable(String)
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "TestFileAudioSource is already running."
        case .fileUnreadable(let message):
            return "Failed to read the KIKIMI_TEST_INPUT WAV file: \(message)"
        case .emptyFile:
            return "The KIKIMI_TEST_INPUT WAV file contains no audio frames."
        }
    }
}

/// Internal `AudioSourceCapturing` implementation that replays a fixed WAV file instead of
/// capturing real hardware input, used to inject deterministic dummy audio via the
/// `KIKIMI_TEST_INPUT` environment variable (see `docs/design/01-audio-capture.md` section 10).
///
/// Behavior:
/// - Loads the WAV file at `fileURL` once, when `start()` is called.
/// - Splits the loaded audio into `chunkFrameCount`-frame chunks (default 1024 frames, ~64ms at
///   16kHz, matching `AudioCaptureConfig.micTapBufferSize`'s default).
/// - Delivers one chunk per `DispatchSourceTimer` tick, paced at real time (tick interval =
///   `chunkFrameCount / sampleRate`).
/// - Loops back to the beginning once the end of the file is reached, and keeps looping
///   indefinitely until `stop()` is called.
/// - Never touches TCC permission dialogs or CoreAudio Process Tap creation; it only reads a
///   local file, so it works headlessly in CI / `kikimi-verify` automation.
///
/// A microphone instance and a system-audio instance are expected to be two independent
/// `TestFileAudioSource` instances (typically pointed at the same file); tagging the delivered
/// buffers with `source: .mic` / `source: .system` is the caller's (`AudioCapture`'s) job, not
/// this type's.
final class TestFileAudioSource: AudioSourceCapturing {
    private let fileURL: URL
    private let chunkFrameCount: AVAudioFrameCount
    /// Test-only hook to bypass the derived real-time pacing (`chunkFrameCount / sampleRate`).
    /// Production callers (and `AudioCapture`'s `KIKIMI_TEST_INPUT` resolution) must leave this `nil`.
    private let tickIntervalOverride: TimeInterval?
    /// Serializes `start()`/`stop()` against timer-driven chunk delivery. The timer is also
    /// driven on this queue, so all mutable state below is only ever touched from here.
    private let stateQueue: DispatchQueue
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "TestFileAudioSource")

    private var timer: DispatchSourceTimer?
    private var sourceBuffer: AVAudioPCMBuffer?
    private var nextChunkStart: AVAudioFrameCount = 0
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var running = false

    /// - Parameters:
    ///   - fileURL: Path to the dummy WAV file (typically the value of `KIKIMI_TEST_INPUT`).
    ///   - chunkFrameCount: Frames per delivered buffer. Defaults to 1024, matching
    ///     `AudioCaptureConfig.micTapBufferSize`'s default.
    ///   - tickIntervalOverride: Test-only override for the delivery pacing. Leave `nil` in
    ///     production so pacing is derived from the file's sample rate.
    ///   - queue: Serial queue the timer and internal state are driven on. Each instance gets
    ///     its own queue by default so mic/system instances never contend with each other.
    init(
        fileURL: URL,
        chunkFrameCount: AVAudioFrameCount = 1024,
        tickIntervalOverride: TimeInterval? = nil,
        queue: DispatchQueue = DispatchQueue(label: "io.github.uphy.Kikimi.TestFileAudioSource")
    ) {
        self.fileURL = fileURL
        self.chunkFrameCount = chunkFrameCount
        self.tickIntervalOverride = tickIntervalOverride
        self.stateQueue = queue
    }

    deinit {
        stop()
    }

    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        try stateQueue.sync {
            guard !running else {
                throw TestFileAudioSourceError.alreadyRunning
            }

            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: fileURL)
            } catch {
                logger.error("Failed to open KIKIMI_TEST_INPUT file \(self.fileURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
                throw TestFileAudioSourceError.fileUnreadable(error.localizedDescription)
            }

            let totalFrames = AVAudioFrameCount(file.length)
            guard totalFrames > 0 else {
                logger.error("KIKIMI_TEST_INPUT file is empty: \(self.fileURL.path, privacy: .public)")
                throw TestFileAudioSourceError.emptyFile
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: totalFrames) else {
                throw TestFileAudioSourceError.fileUnreadable("Unable to allocate a \(totalFrames)-frame PCM buffer.")
            }

            do {
                try file.read(into: buffer)
            } catch {
                logger.error("Failed to read KIKIMI_TEST_INPUT file into memory: \(String(describing: error), privacy: .public)")
                throw TestFileAudioSourceError.fileUnreadable(error.localizedDescription)
            }

            let sampleRate = file.processingFormat.sampleRate
            let tickInterval = tickIntervalOverride ?? (Double(chunkFrameCount) / sampleRate)

            sourceBuffer = buffer
            nextChunkStart = 0
            self.bufferHandler = bufferHandler
            running = true

            let newTimer = DispatchSource.makeTimerSource(queue: stateQueue)
            newTimer.schedule(deadline: .now() + tickInterval, repeating: tickInterval, leeway: .milliseconds(5))
            newTimer.setEventHandler { [weak self] in
                self?.deliverNextChunk()
            }
            timer = newTimer
            newTimer.resume()

            logger.info(
                """
                Started replaying \(totalFrames) frames from \(self.fileURL.lastPathComponent, privacy: .public) \
                in \(self.chunkFrameCount)-frame chunks (~\(Int(tickInterval * 1_000))ms interval)
                """
            )
        }
    }

    func stop() {
        stateQueue.sync {
            guard running else { return }
            running = false
            timer?.cancel()
            timer = nil
            sourceBuffer = nil
            bufferHandler = nil
            nextChunkStart = 0
            logger.info("Stopped replaying \(self.fileURL.lastPathComponent, privacy: .public)")
        }
    }

    /// Only ever invoked on `stateQueue` (the timer's target queue).
    private func deliverNextChunk() {
        guard running, let source = sourceBuffer, let handler = bufferHandler else { return }

        let totalFrames = source.frameLength
        let remaining = totalFrames - nextChunkStart
        let framesToCopy = min(chunkFrameCount, remaining)

        guard let chunk = Self.makeChunk(from: source, start: nextChunkStart, count: framesToCopy) else {
            logger.warning("Failed to slice a KIKIMI_TEST_INPUT chunk; skipping this tick.")
            return
        }

        nextChunkStart += framesToCopy
        if nextChunkStart >= totalFrames {
            // Loop back to the beginning; keep supplying until stop() is called (section 10).
            nextChunkStart = 0
        }

        handler(chunk, AVAudioTime(hostTime: mach_absolute_time()))
    }

    /// Copies `count` frames starting at `start` out of `source` into a freshly allocated buffer.
    /// Supports the PCM storage layouts `AVAudioPCMBuffer` can hold (Float32, Int16, Int32).
    private static func makeChunk(
        from source: AVAudioPCMBuffer,
        start: AVAudioFrameCount,
        count: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard count > 0, let chunk = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: count) else {
            return nil
        }
        chunk.frameLength = count

        let channelCount = Int(source.format.channelCount)
        let startOffset = Int(start)
        let frameCount = Int(count)

        if let sourceFloat = source.floatChannelData, let chunkFloat = chunk.floatChannelData {
            for channel in 0..<channelCount {
                memcpy(chunkFloat[channel], sourceFloat[channel] + startOffset, frameCount * MemoryLayout<Float>.size)
            }
        } else if let sourceInt16 = source.int16ChannelData, let chunkInt16 = chunk.int16ChannelData {
            for channel in 0..<channelCount {
                memcpy(chunkInt16[channel], sourceInt16[channel] + startOffset, frameCount * MemoryLayout<Int16>.size)
            }
        } else if let sourceInt32 = source.int32ChannelData, let chunkInt32 = chunk.int32ChannelData {
            for channel in 0..<channelCount {
                memcpy(chunkInt32[channel], sourceInt32[channel] + startOffset, frameCount * MemoryLayout<Int32>.size)
            }
        } else {
            return nil
        }

        return chunk
    }
}
