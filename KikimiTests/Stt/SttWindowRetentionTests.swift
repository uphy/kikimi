import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `SttWindowRetention` (`Kikimi/Stt/SttWindowRetention.swift`,
/// `docs/design/33-meeting-two-pass-decode.md` MT2/MT6, section 7 layer 1). Drives the pure value
/// type directly with synthetic `SttExtractedChunk`s -- no `SttEngine` actor, no FluidAudio.
@Suite("SttWindowRetention")
struct SttWindowRetentionTests {
    private func chunk(samples: [Float], startElapsed: TimeInterval, endElapsed: TimeInterval) -> SttExtractedChunk {
        SttExtractedChunk(samples: samples, startElapsed: startElapsed, endElapsed: endElapsed)
    }

    // MARK: - MT2 tiling: cut's leftover chunks become the start of the next window

    @Test("cut removes only the matched chunks, leaving the rest retained for the next window (no overlap, no gap)")
    func cutTilesConsecutiveWindows() {
        var retention = SttWindowRetention()
        let c1 = chunk(samples: [1, 2], startElapsed: 0, endElapsed: 1)
        let c2 = chunk(samples: [3, 4], startElapsed: 1, endElapsed: 2)
        let c3 = chunk(samples: [5, 6], startElapsed: 2, endElapsed: 3)
        retention.append(chunk: c1)
        retention.append(chunk: c2)
        retention.append(chunk: c3)

        let firstWindow = retention.cut(throughEndElapsed: 2)

        #expect(firstWindow.samples == [1, 2, 3, 4])
        #expect(firstWindow.startElapsed == 0)
        #expect(firstWindow.endElapsed == 2)
        #expect(firstWindow.truncated == false)
        // c3 was strictly after `throughEndElapsed` -- it must still be retained, not dropped.
        #expect(retention.chunks == [c3])

        let c4 = chunk(samples: [7, 8], startElapsed: 3, endElapsed: 4)
        retention.append(chunk: c4)
        let secondWindow = retention.cut(throughEndElapsed: 4)

        // The second window picks up exactly where the first left off: c3's samples (not
        // re-included from the first cut) plus the newly appended c4, with no gap in between.
        #expect(secondWindow.samples == [5, 6, 7, 8])
        #expect(secondWindow.startElapsed == 2)
        #expect(secondWindow.endElapsed == 4)
        #expect(retention.chunks.isEmpty)
    }

    @Test("cut leaves chunks whose endElapsed is beyond throughEndElapsed untouched")
    func cutOnlyMatchesUpToBound() {
        var retention = SttWindowRetention()
        retention.append(chunk: chunk(samples: [1], startElapsed: 0, endElapsed: 1))
        retention.append(chunk: chunk(samples: [2], startElapsed: 1, endElapsed: 2))

        let window = retention.cut(throughEndElapsed: 1)

        #expect(window.samples == [1])
        #expect(window.endElapsed == 1)
        #expect(retention.chunks.count == 1)
        #expect(retention.chunks.first?.startElapsed == 1)
    }

    @Test("cut on an empty retention returns empty samples and both bounds equal to throughEndElapsed")
    func cutOnEmptyRetention() {
        var retention = SttWindowRetention()

        let window = retention.cut(throughEndElapsed: 5)

        #expect(window.samples.isEmpty)
        #expect(window.startElapsed == 5)
        #expect(window.endElapsed == 5)
        #expect(window.truncated == false)
    }

    // MARK: - MT6 (b): overall cap drops the oldest chunks and marks truncated

    @Test("exceeding maxRetainedSamples drops the oldest chunk and sets truncatedSinceLastCut")
    func overCapDropsOldestAndTruncates() {
        // 10 samples at 16kHz == maxRetainedSeconds of 10/16000.
        var retention = SttWindowRetention(maxRetainedSeconds: TimeInterval(10) / 16_000)
        let c1 = chunk(samples: [1, 2, 3, 4, 5], startElapsed: 0, endElapsed: 1)
        let c2 = chunk(samples: [6, 7, 8, 9, 10], startElapsed: 1, endElapsed: 2)
        let c3 = chunk(samples: [11, 12, 13, 14, 15], startElapsed: 2, endElapsed: 3)

        retention.append(chunk: c1)
        retention.append(chunk: c2)
        #expect(retention.truncatedSinceLastCut == false, "exactly at the cap should not truncate")

        retention.append(chunk: c3)

        #expect(retention.truncatedSinceLastCut == true)
        // c1 (the oldest) was dropped; c2 and c3 remain, back at exactly the cap.
        #expect(retention.chunks == [c2, c3])
        #expect(retention.totalSampleCount == 10)
    }

    // MARK: - MT6 (a): trimLead never sets truncated

    @Test("trimLead keeps only the trailing keepingSeconds worth of samples and never sets truncatedSinceLastCut")
    func trimLeadDoesNotTruncate() {
        var retention = SttWindowRetention()
        let oneSecondChunks = (0..<5).map { index in
            chunk(
                samples: Array(repeating: Float(index), count: 16_000),
                startElapsed: TimeInterval(index),
                endElapsed: TimeInterval(index + 1)
            )
        }
        for c in oneSecondChunks {
            retention.append(chunk: c)
        }
        #expect(retention.totalSampleCount == 5 * 16_000)

        retention.trimLead(keepingSeconds: 2)

        // Keeps at least the trailing 2s (32,000 samples); drops whole leading chunks only.
        #expect(retention.totalSampleCount == 2 * 16_000)
        #expect(retention.chunks == [oneSecondChunks[3], oneSecondChunks[4]])
        #expect(retention.truncatedSinceLastCut == false)
    }

    @Test("trimLead uses defaultKeepingSeconds when no explicit value is passed")
    func trimLeadUsesDefaultKeepingSeconds() {
        var retention = SttWindowRetention(defaultKeepingSeconds: 1)
        for index in 0..<3 {
            retention.append(chunk: chunk(
                samples: Array(repeating: Float(index), count: 16_000),
                startElapsed: TimeInterval(index),
                endElapsed: TimeInterval(index + 1)
            ))
        }

        retention.trimLead()

        #expect(retention.totalSampleCount == 16_000)
    }

    // MARK: - MT6 (b): a single oversized chunk is never evicted down to zero chunks

    @Test("append never drops the last remaining chunk even if it alone exceeds maxRetainedSamples")
    func appendNeverDropsBelowOneChunk() {
        var retention = SttWindowRetention(maxRetainedSeconds: TimeInterval(2) / 16_000)
        let oversizedChunk = chunk(samples: [1, 2, 3, 4, 5], startElapsed: 0, endElapsed: 1)

        retention.append(chunk: oversizedChunk)

        // The cap (2 samples) is smaller than this single chunk (5 samples), but the chunk must
        // still be retained -- dropping it would silently lose audio rather than just marking the
        // next window truncated.
        #expect(retention.chunks == [oversizedChunk])
        #expect(retention.truncatedSinceLastCut == false)
    }

    @Test("exceeding the cap by more than one chunk's worth drops every chunk necessary to fit, not just the oldest one")
    func appendDropsMultipleChunksIfNeededToFitCap() {
        // Cap fits exactly one 5-sample chunk.
        var retention = SttWindowRetention(maxRetainedSeconds: TimeInterval(5) / 16_000)
        let c1 = chunk(samples: [1, 2, 3, 4, 5], startElapsed: 0, endElapsed: 1)
        let c2 = chunk(samples: [6, 7, 8, 9, 10], startElapsed: 1, endElapsed: 2)
        let c3 = chunk(samples: [11, 12, 13, 14, 15], startElapsed: 2, endElapsed: 3)

        retention.append(chunk: c1)
        retention.append(chunk: c2)
        retention.append(chunk: c3)

        // c1 and c2 both had to go to get back under the cap after c3 was appended -- only the
        // most recent chunk remains.
        #expect(retention.chunks == [c3])
        #expect(retention.truncatedSinceLastCut == true)
    }

    // MARK: - MT6 (a): trimLead never drops below one chunk either

    @Test("trimLead never drops the last remaining chunk even if it alone exceeds keepingSeconds")
    func trimLeadNeverDropsBelowOneChunk() {
        var retention = SttWindowRetention()
        let oversizedChunk = chunk(
            samples: Array(repeating: Float(0), count: 5 * 16_000),
            startElapsed: 0,
            endElapsed: 5
        )
        retention.append(chunk: oversizedChunk)

        retention.trimLead(keepingSeconds: 1)

        #expect(retention.chunks == [oversizedChunk])
    }

    // MARK: - cut with nothing matching leaves retention untouched

    @Test("cut where no retained chunk's endElapsed is within bound leaves every chunk retained")
    func cutWithNoMatchingChunksRetainsEverything() {
        var retention = SttWindowRetention()
        let c1 = chunk(samples: [1], startElapsed: 5, endElapsed: 6)
        let c2 = chunk(samples: [2], startElapsed: 6, endElapsed: 7)
        retention.append(chunk: c1)
        retention.append(chunk: c2)

        let window = retention.cut(throughEndElapsed: 1)

        #expect(window.samples.isEmpty)
        #expect(window.startElapsed == 1)
        #expect(window.endElapsed == 1)
        #expect(retention.chunks == [c1, c2])
    }

    // MARK: - truncatedSinceLastCut persists across multiple appends until the next cut

    @Test("truncatedSinceLastCut set by an earlier append stays set through later, non-truncating appends")
    func truncatedFlagPersistsAcrossSubsequentAppends() {
        var retention = SttWindowRetention(maxRetainedSeconds: TimeInterval(5) / 16_000)
        retention.append(chunk: chunk(samples: [1, 2, 3, 4, 5], startElapsed: 0, endElapsed: 1))
        retention.append(chunk: chunk(samples: [6, 7, 8, 9, 10], startElapsed: 1, endElapsed: 2))
        #expect(retention.truncatedSinceLastCut == true, "the second append already forced eviction of the first chunk")

        // A further append that itself doesn't need to evict anything must not clear the flag --
        // it still describes a drop that happened since the last cut.
        retention.append(chunk: chunk(samples: [], startElapsed: 2, endElapsed: 2))

        #expect(retention.truncatedSinceLastCut == true)
    }

    // MARK: - cut resets truncatedSinceLastCut

    @Test("cut resets truncatedSinceLastCut regardless of whether it was set")
    func cutResetsTruncatedFlag() {
        var retention = SttWindowRetention(maxRetainedSeconds: TimeInterval(10) / 16_000)
        retention.append(chunk: chunk(samples: [1, 2, 3, 4, 5], startElapsed: 0, endElapsed: 1))
        retention.append(chunk: chunk(samples: [6, 7, 8, 9, 10], startElapsed: 1, endElapsed: 2))
        retention.append(chunk: chunk(samples: [11, 12, 13, 14, 15], startElapsed: 2, endElapsed: 3))
        #expect(retention.truncatedSinceLastCut == true)

        let firstWindow = retention.cut(throughEndElapsed: 3)

        // The window reports the truncation that happened before this cut...
        #expect(firstWindow.truncated == true)
        // ...but the flag itself is reset for the next tile.
        #expect(retention.truncatedSinceLastCut == false)

        retention.append(chunk: chunk(samples: [16, 17], startElapsed: 3, endElapsed: 4))
        let secondWindow = retention.cut(throughEndElapsed: 4)

        #expect(secondWindow.truncated == false)
    }
}
