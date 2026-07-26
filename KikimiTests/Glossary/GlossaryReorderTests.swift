import Testing

@testable import Kikimi

/// `docs/design/28-glossary.md` §4.3's bucket-relative reorder logic for the 用語集 tab's drag-to-reorder
/// and "上へ/下へ移動" fallback.
@Suite("GlossaryReorder")
struct GlossaryReorderTests {
    private func entry(_ term: String) -> GlossaryEntry {
        GlossaryEntry(term: term, reading: "")
    }

    private func terms(_ entries: [GlossaryEntry]) -> [String] {
        entries.map(\.term)
    }

    // MARK: Contiguous bucket

    @Test("moving an entry up (to: position - 1) swaps it with its previous neighbor")
    func movingUpSwapsWithPreviousNeighbor() {
        let entries = ["A", "B", "C", "D"].map(entry)

        let result = GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 1, 2, 3], from: 2, to: 1)

        #expect(terms(result) == ["A", "C", "B", "D"])
    }

    @Test("moving an entry down (to: position + 2) swaps it with its next neighbor")
    func movingDownSwapsWithNextNeighbor() {
        let entries = ["A", "B", "C", "D"].map(entry)

        let result = GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 1, 2, 3], from: 1, to: 3)

        #expect(terms(result) == ["A", "C", "B", "D"])
    }

    @Test("moving the first entry to the end of the bucket")
    func movingFirstEntryToEnd() {
        let entries = ["A", "B", "C", "D"].map(entry)

        let result = GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 1, 2, 3], from: 0, to: 4)

        #expect(terms(result) == ["B", "C", "D", "A"])
    }

    @Test("moving the last entry to the front of the bucket")
    func movingLastEntryToFront() {
        let entries = ["A", "B", "C", "D"].map(entry)

        let result = GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 1, 2, 3], from: 3, to: 0)

        #expect(terms(result) == ["D", "A", "B", "C"])
    }

    // MARK: Non-contiguous bucket

    @Test("reordering a non-contiguous bucket permutes only its own entries, at their absolute slots")
    func nonContiguousBucketReordersInPlace() {
        // bucketIndices [0, 3, 4] -> bucket order [E0, E3, E4]. Move E0 (position 0) past both other
        // bucket members, to the end of the bucket (to: 3, the bucket's size).
        let entries = ["E0", "E1", "E2", "E3", "E4"].map(entry)

        let result = GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 3, 4], from: 0, to: 3)

        // Absolute slot 0 now holds what was the bucket's second member, slot 3 its third, and slot 4
        // (the entry that moved) holds the first. Slots 1 and 2, outside the bucket, are untouched.
        #expect(terms(result) == ["E3", "E1", "E2", "E4", "E0"])
        #expect(result[1] == entries[1])
        #expect(result[2] == entries[2])
    }

    @Test("a non-contiguous bucket's relative order after reordering is exactly what was asked")
    func nonContiguousBucketRelativeOrder() {
        // bucket order [E0, E3, E4] (bucketIndices [0, 3, 4]). Move bucket position 0 (E0) past both
        // other bucket members, to the end.
        let entries = ["E0", "E1", "E2", "E3", "E4"].map(entry)

        let result = GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 3, 4], from: 0, to: 3)
        let newBucketOrder = [0, 3, 4].map { result[$0].term }

        #expect(newBucketOrder == ["E3", "E4", "E0"])
    }

    // MARK: No-op moves

    @Test("from == to is a no-op and returns entries unchanged")
    func sameFromToIsNoOp() {
        let entries = ["A", "B", "C"].map(entry)

        let result = GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 1, 2], from: 1, to: 1)

        #expect(result == entries)
    }

    @Test("the downward-adjacent move (to: from + 1) is a no-op and returns entries unchanged")
    func downwardAdjacentIsNoOp() {
        let entries = ["A", "B", "C"].map(entry)

        let result = GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 1, 2], from: 0, to: 1)

        #expect(result == entries)
    }

    // MARK: Out-of-range / degenerate arguments

    @Test("an empty bucketIndices returns entries unchanged")
    func emptyBucketIndicesIsUnchanged() {
        let entries = ["A", "B"].map(entry)

        let result = GlossaryReorder.reordered(entries: entries, bucketIndices: [], from: 0, to: 0)

        #expect(result == entries)
    }

    @Test("a single-element bucket returns entries unchanged for any from/to")
    func singleElementBucketIsUnchanged() {
        let entries = ["A", "B", "C"].map(entry)

        #expect(GlossaryReorder.reordered(entries: entries, bucketIndices: [1], from: 0, to: 0) == entries)
        #expect(GlossaryReorder.reordered(entries: entries, bucketIndices: [1], from: 0, to: 1) == entries)
    }

    @Test("an out-of-range from returns entries unchanged")
    func outOfRangeFromIsUnchanged() {
        let entries = ["A", "B", "C"].map(entry)

        #expect(GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 1, 2], from: -1, to: 1) == entries)
        #expect(GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 1, 2], from: 3, to: 1) == entries)
    }

    @Test("an out-of-range to returns entries unchanged")
    func outOfRangeToIsUnchanged() {
        let entries = ["A", "B", "C"].map(entry)

        #expect(GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 1, 2], from: 0, to: -1) == entries)
        #expect(GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 1, 2], from: 0, to: 4) == entries)
    }

    @Test("malformed bucketIndices (unsorted, duplicate, or out of bounds) returns entries unchanged")
    func malformedBucketIndicesIsUnchanged() {
        let entries = ["A", "B", "C"].map(entry)

        #expect(GlossaryReorder.reordered(entries: entries, bucketIndices: [1, 0], from: 0, to: 1) == entries)
        #expect(GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 0], from: 0, to: 1) == entries)
        #expect(GlossaryReorder.reordered(entries: entries, bucketIndices: [0, 5], from: 0, to: 1) == entries)
    }

    // MARK: Round-trip through GlossaryCategorization

    @Test("reordering within a category changes the order GlossaryCategorization.indices(in:) reveals")
    func roundTripsThroughGlossaryCategorization() {
        let categoryId = "env"
        let entries = [
            GlossaryEntry(term: "nekosuke", reading: "", category: "person"),
            GlossaryEntry(term: "stg", reading: "", category: categoryId),
            GlossaryEntry(term: "dev", reading: "", category: categoryId),
            GlossaryEntry(term: "prod", reading: "", category: categoryId),
            GlossaryEntry(term: "Claude", reading: "", category: nil)
        ]

        let bucketIndices = GlossaryCategorization.indices(entries: entries, in: categoryId)
        #expect(bucketIndices == [1, 2, 3])

        // Move "stg" (bucket position 0) to the end of its category.
        let reordered = GlossaryReorder.reordered(entries: entries, bucketIndices: bucketIndices, from: 0, to: 3)

        let newBucketIndices = GlossaryCategorization.indices(entries: reordered, in: categoryId)
        #expect(newBucketIndices.map { reordered[$0].term } == ["dev", "prod", "stg"])

        // Entries outside the category are untouched, in both value and absolute position.
        #expect(reordered[0] == entries[0])
        #expect(reordered[4] == entries[4])
    }
}
