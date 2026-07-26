import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `KnownSpeakerSort.sorted(speakers:slotEmbedding:)`
/// (`Kikimi/ViewModels/KnownSpeakerSort.swift`, `docs/design/13-speaker-diarization.md` section 6.1's
/// rename popover known-speaker picker). Pure/deterministic (no I/O), so every branch is exercised
/// directly here without a `VoiceprintStore`/UI round-trip.
@Suite("KnownSpeakerSort.sorted")
struct KnownSpeakerSortTests {
    private static func speaker(
        id: String,
        embedding: [Float],
        updatedAt: Date
    ) -> VoiceprintSpeaker {
        VoiceprintSpeaker(
            id: id,
            name: id,
            embedding: embedding,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("orders matchable speakers by ascending cosine distance to the slot embedding")
    func ordersByAscendingCosineDistance() {
        // slot points along [1, 0]. `close` is identical (distance 0), `mid` is orthogonal (distance
        // 1), `far` is opposite (distance 2).
        let close = Self.speaker(id: "close", embedding: [1, 0], updatedAt: Self.baseDate)
        let mid = Self.speaker(id: "mid", embedding: [0, 1], updatedAt: Self.baseDate)
        let far = Self.speaker(id: "far", embedding: [-1, 0], updatedAt: Self.baseDate)

        let result = KnownSpeakerSort.sorted(speakers: [far, mid, close], slotEmbedding: [1, 0])

        #expect(result.map(\.id) == ["close", "mid", "far"])
    }

    @Test("nil slot embedding falls back to descending updatedAt (most recently seen first)")
    func nilSlotEmbeddingFallsBackToUpdatedAtDescending() {
        let older = Self.speaker(id: "older", embedding: [1, 0], updatedAt: Self.baseDate)
        let newer = Self.speaker(
            id: "newer", embedding: [0, 1], updatedAt: Self.baseDate.addingTimeInterval(60)
        )

        let result = KnownSpeakerSort.sorted(speakers: [older, newer], slotEmbedding: nil)

        #expect(result.map(\.id) == ["newer", "older"])
    }

    @Test("empty slot embedding array is treated the same as nil (updatedAt descending)")
    func emptySlotEmbeddingFallsBackToUpdatedAtDescending() {
        let older = Self.speaker(id: "older", embedding: [1, 0], updatedAt: Self.baseDate)
        let newer = Self.speaker(
            id: "newer", embedding: [0, 1], updatedAt: Self.baseDate.addingTimeInterval(60)
        )

        let result = KnownSpeakerSort.sorted(speakers: [older, newer], slotEmbedding: [])

        #expect(result.map(\.id) == ["newer", "older"])
    }

    @Test("a speaker with an empty embedding is unmatchable and sorts after every matchable speaker")
    func emptySpeakerEmbeddingSortsToTail() {
        let matchable = Self.speaker(id: "matchable", embedding: [0, 1], updatedAt: Self.baseDate)
        let unmatchable = Self.speaker(
            id: "unmatchable", embedding: [], updatedAt: Self.baseDate.addingTimeInterval(120)
        )

        let result = KnownSpeakerSort.sorted(speakers: [unmatchable, matchable], slotEmbedding: [1, 0])

        // Even though `unmatchable` has the more recent `updatedAt`, it still sorts after the
        // matchable speaker -- distance always wins over the updatedAt tie-break.
        #expect(result.map(\.id) == ["matchable", "unmatchable"])
    }

    @Test("a speaker whose embedding length differs from the slot's is unmatchable and sorts to the tail")
    func dimensionMismatchSortsToTail() {
        let matchable = Self.speaker(id: "matchable", embedding: [0, 1], updatedAt: Self.baseDate)
        let mismatched = Self.speaker(id: "mismatched", embedding: [1, 0, 0], updatedAt: Self.baseDate)

        let result = KnownSpeakerSort.sorted(speakers: [mismatched, matchable], slotEmbedding: [1, 0])

        #expect(result.map(\.id) == ["matchable", "mismatched"])
    }

    @Test("a speaker whose embedding contains NaN is unmatchable and sorts to the tail")
    func nanEmbeddingSortsToTail() {
        let matchable = Self.speaker(id: "matchable", embedding: [0, 1], updatedAt: Self.baseDate)
        let nanSpeaker = Self.speaker(id: "nan", embedding: [Float.nan, 0], updatedAt: Self.baseDate)

        let result = KnownSpeakerSort.sorted(speakers: [nanSpeaker, matchable], slotEmbedding: [1, 0])

        #expect(result.map(\.id) == ["matchable", "nan"])
    }

    @Test("a slot embedding itself containing NaN makes every speaker unmatchable, falling back to updatedAt")
    func nanSlotEmbeddingMakesEverySpeakerUnmatchable() {
        let older = Self.speaker(id: "older", embedding: [1, 0], updatedAt: Self.baseDate)
        let newer = Self.speaker(
            id: "newer", embedding: [0, 1], updatedAt: Self.baseDate.addingTimeInterval(60)
        )

        let result = KnownSpeakerSort.sorted(speakers: [older, newer], slotEmbedding: [Float.nan, 0])

        #expect(result.map(\.id) == ["newer", "older"])
    }

    @Test("multiple unmatchable speakers within the tail group are still ordered by descending updatedAt")
    func tailGroupOrderedByUpdatedAtDescending() {
        let matchable = Self.speaker(id: "matchable", embedding: [0, 1], updatedAt: Self.baseDate)
        let olderUnmatchable = Self.speaker(id: "olderUnmatchable", embedding: [], updatedAt: Self.baseDate)
        let newerUnmatchable = Self.speaker(
            id: "newerUnmatchable", embedding: [], updatedAt: Self.baseDate.addingTimeInterval(60)
        )

        let result = KnownSpeakerSort.sorted(
            speakers: [olderUnmatchable, matchable, newerUnmatchable],
            slotEmbedding: [1, 0]
        )

        #expect(result.map(\.id) == ["matchable", "newerUnmatchable", "olderUnmatchable"])
    }

    @Test("equal-distance matches are tie-broken by descending updatedAt")
    func equalDistanceTiesAreBrokenByUpdatedAtDescending() {
        let olderIdentical = Self.speaker(id: "olderIdentical", embedding: [1, 0], updatedAt: Self.baseDate)
        let newerIdentical = Self.speaker(
            id: "newerIdentical", embedding: [1, 0], updatedAt: Self.baseDate.addingTimeInterval(60)
        )

        let result = KnownSpeakerSort.sorted(
            speakers: [olderIdentical, newerIdentical], slotEmbedding: [1, 0]
        )

        #expect(result.map(\.id) == ["newerIdentical", "olderIdentical"])
    }

    @Test("an empty speaker list returns an empty result regardless of slot embedding")
    func emptySpeakerListReturnsEmpty() {
        #expect(KnownSpeakerSort.sorted(speakers: [], slotEmbedding: [1, 0]).isEmpty)
        #expect(KnownSpeakerSort.sorted(speakers: [], slotEmbedding: nil).isEmpty)
    }
}
