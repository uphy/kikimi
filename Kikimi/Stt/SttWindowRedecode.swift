import Foundation

/// Re-splits one two-pass re-decode window's batch transcription result into
/// `SttFinalizedSegment`s and prorates the window's timestamp span across them
/// (`docs/design/33-meeting-two-pass-decode.md` section 3.4, MT3).
///
/// Pure (no actor, no I/O) so layer-1 tests can drive `resplit` directly -- mirrors the
/// `SttEngine+PureHelpers.swift` convention (section 3.12). Reuses `SttEngine`'s existing
/// punctuation/soft-boundary splitters verbatim (same character sets as streaming routes 1/3) so
/// batch-supplied text is segmented by the same rules as streaming-confirmed text.
enum SttWindowRedecode {
    /// Splits `batchText` into segments by the same sentence-ending rule as streaming route 1
    /// (`SttEngine.splitPendingTextOnPunctuation`), further breaking any piece over
    /// `maxSegmentCharacters` at soft boundaries (route 3's `splitPendingTextAtSoftBoundary`,
    /// applied repeatedly), then distributes `[max(windowStartMs, speechStartMs), windowEndMs]`
    /// across the resulting pieces proportionally to character count.
    ///
    /// - Parameters:
    ///   - batchText: The batch decoder's raw transcription of the window's samples.
    ///   - windowStartMs: The window's start bound at chunk granularity (may include a leading
    ///     silence lead, MT2/MT6 (a)).
    ///   - windowEndMs: The window's end bound; the last returned piece's `endMs` always equals
    ///     this.
    ///   - speechStartMs: The first streaming piece's `startMs` for this window (i.e. where
    ///     `SttEngine` actually detected speech) -- clamps the proration origin so a long silence
    ///     lead never drags a segment's `startMs` before the real speech (MT11).
    ///   - maxSegmentCharacters: Same runaway-guard threshold as `SttEngineConfig
    ///     .maxSegmentCharacters` (route 3).
    /// - Returns: Zero or more segments (empty when `batchText` trims to nothing), each with
    ///   `confidence: 1.0` (section 3.5, unchanged by two-pass).
    static func resplit(
        batchText: String,
        windowStartMs: Int,
        windowEndMs: Int,
        speechStartMs: Int,
        maxSegmentCharacters: Int
    ) -> [SttFinalizedSegment] {
        let punctuationSplit = SttEngine.splitPendingTextOnPunctuation(batchText)
        var pieces = punctuationSplit.confirmedSegments
        if !punctuationSplit.remainingPendingText.isEmpty {
            // No further confirmation event exists to consume this remainder (unlike streaming's
            // MT13) -- the whole batch text describes exactly this window, so any punctuation-less
            // trailing text still belongs in the window as its own (last) piece.
            pieces.append(punctuationSplit.remainingPendingText)
        }

        let expandedPieces = pieces.flatMap { splitLongPiece($0, maxSegmentCharacters: maxSegmentCharacters) }

        let trimmedPieces = expandedPieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !trimmedPieces.isEmpty else {
            return []
        }

        // Clamped to `windowEndMs` too so a pathological `speechStartMs > windowEndMs` never
        // produces a negative span or an origin past the window's own end (keeps the "last piece's
        // endMs == windowEndMs" and "monotonic non-decreasing" guarantees intact regardless of
        // caller input).
        let originMs = min(max(windowStartMs, speechStartMs), windowEndMs)
        let span = windowEndMs - originMs
        let totalCharacters = trimmedPieces.reduce(0) { $0 + $1.count }

        var segments: [SttFinalizedSegment] = []
        var cumulativeCharacters = 0
        var previousEndMs = originMs
        for (index, piece) in trimmedPieces.enumerated() {
            cumulativeCharacters += piece.count
            let startMs = previousEndMs
            let isLastPiece = index == trimmedPieces.count - 1
            let endMs: Int
            if isLastPiece {
                endMs = windowEndMs
            } else {
                let proration = Double(cumulativeCharacters) / Double(totalCharacters)
                let proratedMs = originMs + Int(Double(span) * proration)
                endMs = max(startMs, min(proratedMs, windowEndMs))
            }
            segments.append(SttFinalizedSegment(startMs: startMs, endMs: endMs, text: piece, confidence: 1.0))
            previousEndMs = endMs
        }
        return segments
    }

    /// Repeatedly applies `SttEngine.splitPendingTextAtSoftBoundary` (route 3's soft-boundary
    /// backoff) until what remains no longer exceeds `maxSegmentCharacters`, returning every
    /// confirmed piece plus the final remainder. Each application strictly shortens the remaining
    /// text (the confirmed piece is always >= 1 character), so this always terminates.
    private static func splitLongPiece(_ piece: String, maxSegmentCharacters: Int) -> [String] {
        guard maxSegmentCharacters > 0 else {
            return [piece]
        }

        var result: [String] = []
        var remaining = piece
        while remaining.count > maxSegmentCharacters {
            let split = SttEngine.splitPendingTextAtSoftBoundary(
                remaining,
                maxSegmentCharacters: maxSegmentCharacters,
                softBoundaryCharacters: SttEngineConfig.softBoundaryCharacters
            )
            result.append(contentsOf: split.confirmedSegments)
            remaining = split.remainingPendingText
        }
        if !remaining.isEmpty {
            result.append(remaining)
        }
        return result
    }
}
