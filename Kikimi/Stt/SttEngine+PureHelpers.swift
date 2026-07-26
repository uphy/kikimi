import AVFoundation
import Foundation

// MARK: - SttChunkAccumulator / SttExtractedChunk

/// Per-source raw-sample accumulator feeding `SttStreamingBackend.processChunk(_:)` at exactly
/// `chunkSampleCount` granularity. See `docs/design/11-streaming-stt.md` section 3.1/3.4.
///
/// Declared `internal` (not `private`), like the previous VAD-era `SourceState`/`BufferAnchor`, so
/// section 3.12's layer-1 tests can drive it directly via `@testable import` with synthetic sample
/// arrays.
struct SttChunkAccumulator: Sendable, Equatable {
    /// Samples accumulated toward the chunk currently in progress (always `< chunkSampleCount` once
    /// `accumulateAndExtractChunks` returns).
    var samples: [Float] = []
    /// The `elapsedAtBufferStart` recorded when `samples` first became non-empty — i.e. the wall-clock
    /// time (seconds since `AudioCapture.start()`) at which the in-progress chunk started
    /// accumulating. `nil` exactly when `samples.isEmpty`.
    var startElapsed: TimeInterval?
}

/// One full chunk ready to hand to `SttStreamingBackend.processChunk(_:)`, with the buffer-granularity
/// elapsed-time bounds `SttEngine` needs to resolve `SttFinalizedSegment.startMs`/`endMs` (section 3.4).
struct SttExtractedChunk: Sendable, Equatable {
    var samples: [Float]
    /// Elapsed time (seconds since `AudioCapture.start()`) at which this chunk started accumulating.
    var startElapsed: TimeInterval
    /// Elapsed time at which this chunk was completed (the `feed()` call whose buffer pushed the
    /// accumulator over `chunkSampleCount`, or — for `flushChunk` — the elapsed time `stop()` was
    /// called at). Chunk-granularity approximation, matching section 3.4's stated precision.
    var endElapsed: TimeInterval
}

// MARK: - SttSegmentSplitResult

/// Result of scanning a pending (unconfirmed) segment's text for sentence-ending punctuation
/// (`docs/design/11-streaming-stt.md` section 3.3 route 1). A single chunk can in principle contain
/// more than one complete sentence, so this returns every confirmed piece found, in order, plus
/// whatever text remains pending after the last one.
struct SttSegmentSplitResult: Sendable, Equatable {
    var confirmedSegments: [String]
    var remainingPendingText: String
}

// MARK: - SttEngine + Pure helpers (section 3.12: kept as `static` functions for direct unit testing)

/// `SttEngine`'s side-effect-free helpers, split into their own file (mirroring the previous VAD-era
/// split) to keep `SttEngine.swift` under the project's `file_length` lint limit. Declared `internal`
/// so `KikimiTests` can call them directly via `@testable import Kikimi` without an actor instance,
/// a real FluidAudio model, or `async`/`await`.
extension SttEngine {
    static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return []
        }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return []
        }
        // Defense in depth: `floatChannelData` can be non-nil while the first channel pointer is
        // still NULL if the buffer object is observed mid-(lazy-)initialization from another
        // thread (AVAudioPCMBuffer is not thread-safe; crash 2026-07-02: memmove from 0x0). The
        // real fix is that callers must extract on the producer's queue before crossing threads
        // (TranscriptPipeline.didCapture), but never dereference a null channel pointer either way.
        let channelPointer = channelData[0]
        guard Int(bitPattern: channelPointer) != 0 else {
            return []
        }
        let samples = UnsafeBufferPointer(start: channelPointer, count: frameLength)
        return Array(samples)
    }

    // MARK: Chunk accumulation (section 3.1/3.4)

    /// Appends `newSamples` to `accumulator` and extracts as many full `chunkSampleCount`-sized
    /// chunks as are now available (usually zero or one per `feed()` call, but a large buffer — or a
    /// short `chunkMs` tier — can yield more than one). `accumulator` is left holding the remainder
    /// (`< chunkSampleCount` samples).
    static func accumulateAndExtractChunks(
        accumulator: inout SttChunkAccumulator,
        newSamples: [Float],
        elapsedAtBufferStart: TimeInterval,
        chunkSampleCount: Int
    ) -> [SttExtractedChunk] {
        guard chunkSampleCount > 0 else {
            return []
        }
        if accumulator.samples.isEmpty {
            accumulator.startElapsed = elapsedAtBufferStart
        }
        accumulator.samples.append(contentsOf: newSamples)

        var extracted: [SttExtractedChunk] = []
        while accumulator.samples.count >= chunkSampleCount {
            let chunkSamples = Array(accumulator.samples.prefix(chunkSampleCount))
            let startElapsed = accumulator.startElapsed ?? elapsedAtBufferStart
            extracted.append(
                SttExtractedChunk(samples: chunkSamples, startElapsed: startElapsed, endElapsed: elapsedAtBufferStart)
            )
            accumulator.samples.removeFirst(chunkSampleCount)
            accumulator.startElapsed = accumulator.samples.isEmpty ? nil : elapsedAtBufferStart
        }
        return extracted
    }

    /// `stop()`'s forced-flush path (section 3.2/3.3 route 4): zero-pads whatever remains in
    /// `accumulator` up to `chunkSampleCount` and returns it as one final chunk, or `nil` if nothing
    /// was ever accumulated.
    static func flushChunk(
        accumulator: SttChunkAccumulator,
        elapsedAtBufferStart: TimeInterval,
        chunkSampleCount: Int
    ) -> SttExtractedChunk? {
        guard !accumulator.samples.isEmpty, chunkSampleCount > 0 else {
            return nil
        }
        var samples = accumulator.samples
        if samples.count < chunkSampleCount {
            samples.append(contentsOf: repeatElement(Float(0), count: chunkSampleCount - samples.count))
        }
        let startElapsed = accumulator.startElapsed ?? elapsedAtBufferStart
        return SttExtractedChunk(samples: samples, startElapsed: startElapsed, endElapsed: elapsedAtBufferStart)
    }

    // MARK: Cumulative text -> pending text (spike `incrementalTextMode: "cumulative"`)

    /// The as-yet-unconfirmed suffix of `cumulativeText`, i.e. everything beyond the first
    /// `confirmedCharacterCount` characters already emitted as `SttFinalizedSegment`s. Character-count
    /// (not byte) indexed, since `confirmedCharacterCount` is always advanced by `text.count` of
    /// confirmed pieces (section 3.3).
    static func computePendingText(cumulativeText: String, confirmedCharacterCount: Int) -> String {
        guard confirmedCharacterCount < cumulativeText.count else {
            return ""
        }
        let index = cumulativeText.index(cumulativeText.startIndex, offsetBy: confirmedCharacterCount)
        return String(cumulativeText[index...])
    }

    // MARK: Segment confirmation (section 3.3's four routes)

    /// Route 1 (punctuation): splits `pendingText` at every sentence-ending character, returning each
    /// confirmed piece (inclusive of its terminating punctuation) in order, plus whatever trails the
    /// last one. Returns `confirmedSegments: []` and the original text unchanged when no punctuation
    /// is present.
    static func splitPendingTextOnPunctuation(
        _ pendingText: String,
        sentenceEndingCharacters: Set<Character> = SttEngineConfig.sentenceEndingCharacters
    ) -> SttSegmentSplitResult {
        var confirmed: [String] = []
        var remainder = Substring(pendingText)
        while let index = remainder.firstIndex(where: { sentenceEndingCharacters.contains($0) }) {
            confirmed.append(String(remainder[remainder.startIndex...index]))
            remainder = remainder[remainder.index(after: index)...]
        }
        return SttSegmentSplitResult(confirmedSegments: confirmed, remainingPendingText: String(remainder))
    }

    /// Route 3 (max characters, a runaway guard): `true` once `pendingText` exceeds
    /// `maxSegmentCharacters` — the caller force-confirms the entire remainder in that case.
    static func shouldForceConfirmOnMaxCharacters(pendingText: String, maxSegmentCharacters: Int) -> Bool {
        pendingText.count > maxSegmentCharacters
    }

    /// Route 3's soft-boundary backoff (`docs/design/03-refinement-batch.md` section 15.1): rather than
    /// force-confirming all of `pendingText` the instant it exceeds `maxSegmentCharacters` (cutting mid-word),
    /// scan the first `maxSegmentCharacters` characters for the *last* `softBoundaryCharacters` occurrence and
    /// confirm only up to and including it, leaving the rest pending. Falls back to confirming the entire
    /// `pendingText` (matching the pre-15.1 behavior) when no soft boundary character appears within that
    /// range — this preserves the runaway guard for URLs/long alphanumeric runs with no natural cut point.
    ///
    /// Callers are expected to only invoke this once `shouldForceConfirmOnMaxCharacters` is already `true`
    /// (i.e. `pendingText.count > maxSegmentCharacters`), but it degrades gracefully (returns `pendingText`
    /// confirmed whole) if called with shorter text too.
    static func splitPendingTextAtSoftBoundary(
        _ pendingText: String,
        maxSegmentCharacters: Int,
        softBoundaryCharacters: Set<Character>
    ) -> SttSegmentSplitResult {
        let confirmWholeText = SttSegmentSplitResult(confirmedSegments: [pendingText], remainingPendingText: "")
        guard maxSegmentCharacters > 0, pendingText.count > maxSegmentCharacters else {
            return confirmWholeText
        }

        let searchRangeEnd = pendingText.index(pendingText.startIndex, offsetBy: maxSegmentCharacters)
        let searchRange = pendingText[pendingText.startIndex..<searchRangeEnd]
        guard let lastBoundaryIndex = searchRange.lastIndex(where: { softBoundaryCharacters.contains($0) }) else {
            return confirmWholeText
        }

        let confirmedEnd = pendingText.index(after: lastBoundaryIndex)
        let confirmed = String(pendingText[pendingText.startIndex..<confirmedEnd])
        let remainder = String(pendingText[confirmedEnd...])
        return SttSegmentSplitResult(confirmedSegments: [confirmed], remainingPendingText: remainder)
    }

    /// Route 2 (idle timeout): `true` once `pendingText` is non-empty and `elapsedSinceLastGrowth`
    /// (seconds since the cumulative text last actually grew) has reached `segmentIdleTimeout` —
    /// recovers utterances that never receive trailing punctuation.
    static func shouldConfirmOnIdleTimeout(
        pendingText: String,
        elapsedSinceLastGrowth: TimeInterval,
        segmentIdleTimeout: TimeInterval
    ) -> Bool {
        !pendingText.isEmpty && elapsedSinceLastGrowth >= segmentIdleTimeout
    }
}
