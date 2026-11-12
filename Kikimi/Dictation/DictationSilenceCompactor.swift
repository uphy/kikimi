import FluidAudio
import Foundation
import os

// MARK: - DictationSilenceCompactor

/// Shortens the audio handed to the key-up batch re-decode by cutting long silences out of it
/// (`docs/design/51-dictation-silence-skip.md` SS1-SS6). Pure: takes the samples plus per-frame
/// speech probabilities (from `DictationSpeechDetecting`) and returns the compacted samples, or
/// `nil` when the original samples should be decoded unchanged.
enum DictationSilenceCompactor {
    struct Parameters: Equatable, Sendable {
        /// SS3: a frame whose speech probability is at or above this counts as speech.
        var speechThreshold: Float = 0.5
        /// SS3: padding added before and after each speech run, in samples.
        var paddingSamples: Int = 4_800
        /// SS3: padded speech runs separated by less than this are joined into one, in samples.
        var minSilenceSamples: Int = 12_800
        /// SS4: zeros inserted where a silence was cut, in samples.
        var keptGapSamples: Int = 4_800
        /// SS6 (2): compaction that saves less than this is skipped, in samples.
        var minSavedSamples: Int = 16_000

        static let `default` = Parameters()
    }

    struct Result: Equatable, Sendable {
        let samples: [Float]
        /// The kept ranges of the original samples, in order (for logging and tests).
        let keptRanges: [Range<Int>]
    }

    /// - Parameters:
    ///   - samples: The whole utterance, 16kHz mono.
    ///   - probabilities: One speech probability per `frameSampleCount`-sized frame, frame `i`
    ///     covering `samples[i * frameSampleCount ..< (i + 1) * frameSampleCount]` (the last frame
    ///     may be short).
    ///   - frameSampleCount: The detector's frame size (`VadManager.chunkSize`, 4096 = 256ms).
    /// - Returns: `nil` when no frame is speech (SS6 (1)) or the saving is below
    ///   `minSavedSamples` (SS6 (2)).
    static func compact(
        samples: [Float],
        probabilities: [Float],
        frameSampleCount: Int,
        parameters: Parameters = .default
    ) -> Result? {
        guard !samples.isEmpty, frameSampleCount > 0 else { return nil }
        let total = samples.count

        // Speech frames -> padded ranges, clamped to the audio.
        var padded: [Range<Int>] = []
        for (index, probability) in probabilities.enumerated() where probability >= parameters.speechThreshold {
            let frameStart = index * frameSampleCount
            guard frameStart < total else { break }
            let frameEnd = min(frameStart + frameSampleCount, total)
            let lower = max(0, frameStart - parameters.paddingSamples)
            let upper = min(total, frameEnd + parameters.paddingSamples)
            padded.append(lower..<upper)
        }
        guard !padded.isEmpty else { return nil }

        // Join ranges whose gap is shorter than `minSilenceSamples` (overlaps included).
        var kept: [Range<Int>] = []
        for range in padded {
            if let last = kept.last, range.lowerBound - last.upperBound < parameters.minSilenceSamples {
                kept[kept.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                kept.append(range)
            }
        }

        let keptSampleCount = kept.reduce(0) { $0 + $1.count }
        let outputCount = keptSampleCount + parameters.keptGapSamples * (kept.count - 1)
        guard total - outputCount >= parameters.minSavedSamples else { return nil }

        var output: [Float] = []
        output.reserveCapacity(outputCount)
        for (index, range) in kept.enumerated() {
            if index > 0 {
                output.append(contentsOf: repeatElement(0, count: parameters.keptGapSamples))
            }
            output.append(contentsOf: samples[range])
        }
        return Result(samples: output, keptRanges: kept)
    }
}

// MARK: - DictationSpeechDetecting

/// `DictationController`'s seam for the VAD (design 51 §3). Tests inject a fake that never loads
/// the Silero model.
protocol DictationSpeechDetecting: Sendable {
    /// Size of one probability frame, in samples.
    var frameSampleCount: Int { get }
    /// Loads the model ahead of the first utterance (SS8). Never throws; a failure is logged and
    /// retried by the next `speechProbabilities` call.
    func warm() async
    /// One speech probability per `frameSampleCount` samples, starting from a fresh VAD state.
    func speechProbabilities(samples: [Float]) async throws -> [Float]
}

// MARK: - DictationVadSpeechDetector

/// Silero VAD via FluidAudio's `VadManager`, loaded once and reused across utterances (SS8). The
/// first load downloads the model into `~/Library/Application Support/FluidAudio/`.
actor DictationVadSpeechDetector: DictationSpeechDetecting {
    nonisolated let frameSampleCount = VadManager.chunkSize

    private var manager: VadManager?
    private var loadTask: Task<VadManager, Error>?

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationVadSpeechDetector")

    func warm() async {
        do {
            _ = try await loadedManager()
        } catch {
            Self.logger.warning("failed to load the VAD model; dictation will decode silences too: \(String(describing: error), privacy: .public)")
        }
    }

    func speechProbabilities(samples: [Float]) async throws -> [Float] {
        let manager = try await loadedManager()
        return try await manager.process(samples).map(\.probability)
    }

    /// Single-flight load: a key-up that lands mid-warm joins the same load (SS8). A failed load is
    /// cleared so the next call retries instead of rethrowing a stale error.
    private func loadedManager() async throws -> VadManager {
        if let manager { return manager }
        let task: Task<VadManager, Error>
        if let loadTask {
            task = loadTask
        } else {
            task = Task { try await VadManager() }
            loadTask = task
        }
        do {
            let loaded = try await task.value
            manager = loaded
            loadTask = nil
            return loaded
        } catch {
            loadTask = nil
            throw error
        }
    }
}
