import AVFoundation
import Foundation
import OSLog

/// Failure modes surfaced by `WavFileWriter`. Delivered to the `onFailure` callback passed to
/// `append(_:onFailure:)`, and also used internally for `init` throw sites.
enum WavFileWriterError: LocalizedError, Equatable {
    case unableToCreateFile(String)
    case unableToOpenFileHandle(String)
    case unableToCreateFormat
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unableToCreateFile(let path):
            return "Failed to create the WAV file at \(path)."
        case .unableToOpenFileHandle(let path):
            return "Failed to open a file handle for the WAV file at \(path)."
        case .unableToCreateFormat:
            return "Failed to create an audio format for WAV conversion."
        case .conversionFailed(let message):
            return "Failed to convert an audio buffer for WAV writing: \(message)"
        }
    }
}

/// Persists a single audio stream (mic or system) to a 16-bit PCM WAV file
/// (`sessions/<id>/audio/mic.wav` / `system.wav`, see `docs/design/01-audio-capture.md` section 5.2/8).
///
/// Owns a dedicated serial `writerQueue` that all `FileHandle` access (both appends and the
/// periodic header rewrite) is funneled through, so the two never race (section 8). `append(_:onFailure:)`
/// never blocks the calling thread: it only enqueues work onto `writerQueue` and returns immediately.
final class WavFileWriter {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "WavFileWriter")

    /// Dedicated serial queue that serializes every `FileHandle` operation (appends and header
    /// rewrites) for this instance's file. Independent of any other `WavFileWriter`'s queue and of
    /// `AudioCapture.eventQueue` (section 3/8): disk I/O delays here never propagate elsewhere.
    private let writerQueue: DispatchQueue

    private let fileHandle: FileHandle
    private let sampleRate: Double
    private let channels: AVAudioChannelCount
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    /// Total bytes of sample data written so far (the `data` chunk size). Only ever touched on `writerQueue`.
    private var dataByteCount: UInt32 = 0

    /// Set once `close()` has run. Only ever touched on `writerQueue`.
    private var isClosed = false

    /// Set once `append` has failed once and `onFailure` has fired. Once true, further `append`
    /// calls are silently ignored (section 8/9, failure mode #7). Only ever touched on `writerQueue`.
    private var isFailed = false

    private var headerFlushTimer: DispatchSourceTimer?

    /// Creates `fileURL`, writes a placeholder (zero-size) `WavHeader`, and starts the periodic
    /// header-rewrite timer (`headerFlushInterval`) on a dedicated serial `writerQueue`.
    ///
    /// The parent directory of `fileURL` must already exist; creating `sessions/<id>/audio/` is
    /// `AudioCapture`'s responsibility (see design doc section 12), not this type's.
    init(fileURL: URL, sampleRate: Double, channels: AVAudioChannelCount, headerFlushInterval: TimeInterval) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        self.writerQueue = DispatchQueue(label: "io.github.uphy.Kikimi.WavFileWriter.\(fileURL.lastPathComponent)")

        // Downstream buffers handed to `append` are always Float32 standard-format (non-interleaved),
        // matching the format `AudioCapture` uses for its `didCapture` delegate callback (section 7.1/8).
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            throw WavFileWriterError.unableToCreateFormat
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: true
        ) else {
            throw WavFileWriterError.unableToCreateFormat
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw WavFileWriterError.unableToCreateFormat
        }
        self.outputFormat = outputFormat
        self.converter = converter

        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw WavFileWriterError.unableToCreateFile(fileURL.path)
        }
        guard let fileHandle = FileHandle(forWritingAtPath: fileURL.path) else {
            // Clean up the just-created (empty) file so a rare handle-open failure doesn't leave a
            // stray artifact behind in `sessions/<id>/audio/`.
            try? FileManager.default.removeItem(atPath: fileURL.path)
            throw WavFileWriterError.unableToOpenFileHandle(fileURL.path)
        }
        self.fileHandle = fileHandle

        let placeholderHeader = WavHeader(sampleRate: UInt32(sampleRate), channels: UInt16(channels), bitsPerSample: 16, dataByteCount: 0)
        do {
            try fileHandle.write(contentsOf: placeholderHeader.encode())
        } catch {
            // Same cleanup rationale as the FileHandle-open failure above: don't leave a stray,
            // headerless file behind if the very first write fails.
            try? fileHandle.close()
            try? FileManager.default.removeItem(atPath: fileURL.path)
            throw error
        }

        startHeaderFlushTimer(interval: headerFlushInterval)
    }

    deinit {
        // Safety net in case `close()` was never called: stop the timer so it doesn't keep firing
        // against a file handle whose owner is gone. Normal usage always calls `close()` explicitly.
        headerFlushTimer?.cancel()
    }

    /// Converts `buffer` (Float32 standard format) to Int16 interleaved PCM and appends it to the
    /// file. Returns immediately; the conversion and `FileHandle` write happen asynchronously on
    /// `writerQueue`, so the calling thread (an audio callback) is never blocked.
    ///
    /// On failure, calls `onFailure` exactly once, on `writerQueue`, and gives up on all further
    /// `append` calls for this instance (section 8/9).
    func append(_ buffer: AVAudioPCMBuffer, onFailure: @escaping @Sendable (Error) -> Void) {
        writerQueue.async { [weak self] in
            self?.appendOnQueue(buffer, onFailure: onFailure)
        }
    }

    /// Rewrites the WAV header with the final `dataByteCount` and closes the file. Waits
    /// synchronously (via `writerQueue`) for any in-flight appends to finish first. Safe to call
    /// more than once; the second call is a no-op.
    func close() {
        writerQueue.sync { [weak self] in
            self?.closeOnQueue()
        }
    }

    // MARK: - writerQueue-only implementation

    private func appendOnQueue(_ buffer: AVAudioPCMBuffer, onFailure: @escaping @Sendable (Error) -> Void) {
        guard !isClosed, !isFailed else {
            return
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = max(1, AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            fail(with: WavFileWriterError.conversionFailed("Unable to allocate an output buffer"), onFailure: onFailure)
            return
        }

        var conversionError: NSError?
        var providedInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if providedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            outputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil else {
            fail(with: conversionError ?? WavFileWriterError.conversionFailed("Unknown conversion error"), onFailure: onFailure)
            return
        }

        guard outputBuffer.frameLength > 0 else {
            return
        }

        guard let channelData = outputBuffer.int16ChannelData else {
            fail(with: WavFileWriterError.conversionFailed("Converted buffer has no int16 channel data"), onFailure: onFailure)
            return
        }

        let byteCount = Int(outputBuffer.frameLength) * Int(channels) * MemoryLayout<Int16>.size
        let sampleData = Data(bytes: channelData[0], count: byteCount)

        do {
            try fileHandle.write(contentsOf: sampleData)
            dataByteCount += UInt32(byteCount)
        } catch {
            fail(with: error, onFailure: onFailure)
        }
    }

    private func fail(with error: Error, onFailure: @escaping @Sendable (Error) -> Void) {
        guard !isFailed else {
            return
        }
        isFailed = true
        logger.error("WavFileWriter append failed, giving up on further writes: \(error.localizedDescription, privacy: .public)")
        onFailure(error)
    }

    private func closeOnQueue() {
        guard !isClosed else {
            return
        }
        isClosed = true
        headerFlushTimer?.cancel()
        headerFlushTimer = nil

        writeHeader()
        do {
            try fileHandle.close()
        } catch {
            logger.error("Failed to close the WAV file handle: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startHeaderFlushTimer(interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.flushHeaderOnQueue()
        }
        timer.resume()
        headerFlushTimer = timer
    }

    private func flushHeaderOnQueue() {
        guard !isClosed else {
            return
        }
        writeHeader()
    }

    /// Rewinds to the start of the file, rewrites the two size fields of the WAV header with the
    /// current `dataByteCount`, then seeks back to the end so appends can continue (section 8).
    private func writeHeader() {
        let header = WavHeader(sampleRate: UInt32(sampleRate), channels: UInt16(channels), bitsPerSample: 16, dataByteCount: dataByteCount)
        do {
            try fileHandle.seek(toOffset: 0)
            try fileHandle.write(contentsOf: header.encode())
            _ = try fileHandle.seekToEnd()
        } catch {
            logger.error("Failed to flush the WAV header: \(error.localizedDescription, privacy: .public)")
        }
    }
}
