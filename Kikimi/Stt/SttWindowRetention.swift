import Foundation

/// In-memory, chunk-granularity retention of the samples backing the two-pass re-decode window
/// (`docs/design/33-meeting-two-pass-decode.md` MT2/MT6, section 3.2). `SttEngine` appends every
/// chunk it extracts (decode success or failure -- the audio itself is still part of the window
/// tile) and, at each confirmation event that cuts a window, hands the cut-through chunks to
/// `BatchAsrDecoder` for re-decoding while the remainder stays retained for the *next* window
/// (MT2's tiling: windows never overlap and never gap).
///
/// Pure value type (no actor, no I/O) so layer-1 tests can drive it directly with synthetic
/// `SttExtractedChunk`s -- mirrors the `SttEngine+PureHelpers.swift` convention (section 3.12).
struct SttWindowRetention: Sendable, Equatable {
    /// Matches the sample rate assumed throughout the STT pipeline (`RealtimeDiarizationCoordinator
    /// .sampleRateHz` etc.) -- `SttExtractedChunk.samples` is always 16kHz mono Float32.
    static let sampleRateHz = 16_000

    /// Chunks currently retained, in arrival order. The oldest chunk is `chunks.first`.
    private(set) var chunks: [SttExtractedChunk] = []

    /// Set by `append(chunk:)` once the overall retention cap (MT6 (b)) has forced chunks to be
    /// dropped from the front since the last `cut(throughEndElapsed:)`. Consumers (`SttEngine`/
    /// `TranscriptPipeline`) must treat the next cut window as beheaded and fall back to the
    /// streaming pieces instead of re-decoding it (MT4).
    private(set) var truncatedSinceLastCut: Bool = false

    /// The overall retention cap (MT6 (b)), in samples. Exceeding this while pending text is
    /// non-empty (i.e. during real speech, not just a silence lead) drops the oldest chunks and
    /// marks the window `truncated`.
    let maxRetainedSamples: Int

    /// The trailing window (MT6 (a)) that `trimLead(keepingSeconds:)` falls back to when the
    /// caller doesn't pass an explicit value -- lets tests construct a retention with both knobs
    /// pre-set instead of threading `keepingSeconds` through every call.
    let defaultKeepingSeconds: TimeInterval

    /// - Parameters:
    ///   - maxRetainedSeconds: The overall cap (MT6 (b)), default 120s (~7.7MB/source at 16kHz
    ///     mono Float32).
    ///   - defaultKeepingSeconds: The silence-lead trim target (MT6 (a)), default ~20s. Used by
    ///     `trimLead(keepingSeconds:)` when no explicit value is passed.
    init(maxRetainedSeconds: TimeInterval = 120, defaultKeepingSeconds: TimeInterval = 20) {
        self.maxRetainedSamples = Int((maxRetainedSeconds * Double(Self.sampleRateHz)).rounded())
        self.defaultKeepingSeconds = defaultKeepingSeconds
    }

    /// Total sample count currently retained across all chunks.
    var totalSampleCount: Int {
        chunks.reduce(0) { $0 + $1.samples.count }
    }

    /// Appends `chunk` in arrival order (MT2's tiling relies on chunks always being appended in
    /// the order `SttEngine` extracted them). If the total retained sample count now exceeds
    /// `maxRetainedSamples`, drops chunks from the front (oldest first) until it no longer does,
    /// and marks `truncatedSinceLastCut = true` (MT6 (b)) -- this only fires during real,
    /// sustained speech (route 3 force-confirms at 120 characters well before 120s of audio would
    /// accumulate in practice), never during the silence-lead case `trimLead` handles.
    mutating func append(chunk: SttExtractedChunk) {
        chunks.append(chunk)
        while totalSampleCount > maxRetainedSamples, chunks.count > 1 {
            chunks.removeFirst()
            truncatedSinceLastCut = true
        }
    }

    /// Drops chunks from the front, keeping only the trailing `keepingSeconds` (default
    /// `defaultKeepingSeconds`) worth of samples (MT6 (a)). Called by `SttEngine` when the
    /// pending text is empty -- i.e. the retained samples are just the next window's silence
    /// lead -- so a long pause doesn't force the following window to re-decode tens of seconds of
    /// silence. Unlike `append`, this is expected, steady-state behavior, so it never sets
    /// `truncatedSinceLastCut`.
    mutating func trimLead(keepingSeconds: TimeInterval? = nil) {
        let keepingSamples = Int(((keepingSeconds ?? defaultKeepingSeconds) * Double(Self.sampleRateHz)).rounded())
        while totalSampleCount - (chunks.first?.samples.count ?? 0) >= keepingSamples, chunks.count > 1 {
            chunks.removeFirst()
        }
    }

    /// Cuts out every chunk whose `endElapsed <= throughEndElapsed`, in arrival order, removing
    /// them from retention -- the chunks strictly after that point remain retained as the start of
    /// the *next* window (MT2's tiling: no overlap, no gap between consecutive cuts). Resets
    /// `truncatedSinceLastCut` to `false` regardless of whether anything was cut, since the flag
    /// only describes drops since the *last* cut.
    ///
    /// - Returns: The concatenated samples of the cut chunks, the first cut chunk's
    ///   `startElapsed`, the last cut chunk's `endElapsed`, and whether the retention cap dropped
    ///   any leading chunks since the previous cut. When nothing matches (e.g. an empty
    ///   retention), `samples` is empty and both elapsed bounds fall back to `throughEndElapsed`.
    mutating func cut(throughEndElapsed: TimeInterval) -> (samples: [Float], startElapsed: TimeInterval, endElapsed: TimeInterval, truncated: Bool) {
        var cutChunks: [SttExtractedChunk] = []
        while let first = chunks.first, first.endElapsed <= throughEndElapsed {
            cutChunks.append(first)
            chunks.removeFirst()
        }

        let truncated = truncatedSinceLastCut
        truncatedSinceLastCut = false

        let samples = cutChunks.flatMap(\.samples)
        let startElapsed = cutChunks.first?.startElapsed ?? throughEndElapsed
        let endElapsed = cutChunks.last?.endElapsed ?? throughEndElapsed
        return (samples, startElapsed, endElapsed, truncated)
    }
}
