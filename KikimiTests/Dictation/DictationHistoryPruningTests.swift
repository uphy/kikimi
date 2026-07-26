import Foundation
import Testing

@testable import Kikimi

@Suite("DictationHistoryPruning")
struct DictationHistoryPruningTests {
    /// Builds a fixture entry; `offset` seconds after a fixed epoch so ordering is deterministic and
    /// readable (larger offset == newer).
    private static func entry(_ id: String, offset: TimeInterval, isComplete: Bool = true) -> (id: String, recordedAt: Date, isComplete: Bool) {
        (id: id, recordedAt: Date(timeIntervalSince1970: offset), isComplete: isComplete)
    }

    @Test("exactly at maxEntries deletes nothing")
    func exactlyAtLimitDeletesNothing() {
        let existing = [
            Self.entry("a", offset: 0),
            Self.entry("b", offset: 1),
            Self.entry("c", offset: 2),
        ]

        let result = DictationHistoryPruning.entriesToDelete(existing: existing, activeEntryId: nil, maxEntries: 3)

        #expect(result.isEmpty)
    }

    @Test("one over maxEntries deletes only the single oldest entry")
    func oneOverLimitDeletesOldestOnly() {
        let existing = [
            Self.entry("a", offset: 0),
            Self.entry("b", offset: 1),
            Self.entry("c", offset: 2),
            Self.entry("d", offset: 3),
        ]

        let result = DictationHistoryPruning.entriesToDelete(existing: existing, activeEntryId: nil, maxEntries: 3)

        #expect(result == ["a"])
    }

    @Test("far over maxEntries deletes all overflow, oldest first")
    func farOverLimitDeletesAllOverflowOldestFirst() {
        let existing = [
            Self.entry("a", offset: 0),
            Self.entry("b", offset: 1),
            Self.entry("c", offset: 2),
            Self.entry("d", offset: 3),
            Self.entry("e", offset: 4),
            Self.entry("f", offset: 5),
        ]

        let result = DictationHistoryPruning.entriesToDelete(existing: existing, activeEntryId: nil, maxEntries: 2)

        #expect(result == ["a", "b", "c", "d"])
    }

    @Test("maxEntries of 1 keeps only the single newest complete entry")
    func maxEntriesOfOneKeepsOnlyNewest() {
        let existing = [
            Self.entry("a", offset: 0),
            Self.entry("b", offset: 1),
            Self.entry("c", offset: 2),
        ]

        let result = DictationHistoryPruning.entriesToDelete(existing: existing, activeEntryId: nil, maxEntries: 1)

        #expect(result == ["a", "b"])
    }

    @Test("orphans are deleted unconditionally, independent of the entry count vs maxEntries")
    func orphansAreDeletedUnconditionally() {
        let existing = [
            Self.entry("orphan-1", offset: 0, isComplete: false),
            Self.entry("a", offset: 1),
        ]

        let result = DictationHistoryPruning.entriesToDelete(existing: existing, activeEntryId: nil, maxEntries: 100)

        #expect(result == ["orphan-1"])
    }

    @Test("the active entry is excluded even when it is an orphan")
    func activeEntryExcludedWhenOrphan() {
        let existing = [
            Self.entry("active-orphan", offset: 0, isComplete: false),
            Self.entry("a", offset: 1),
        ]

        let result = DictationHistoryPruning.entriesToDelete(existing: existing, activeEntryId: "active-orphan", maxEntries: 100)

        #expect(result.isEmpty)
    }

    @Test("the active entry is excluded even when it would otherwise be the oldest overflow candidate")
    func activeEntryExcludedFromOverflow() {
        let existing = [
            Self.entry("active", offset: 0),
            Self.entry("b", offset: 1),
            Self.entry("c", offset: 2),
            Self.entry("d", offset: 3),
        ]

        let result = DictationHistoryPruning.entriesToDelete(existing: existing, activeEntryId: "active", maxEntries: 2)

        #expect(result == ["b"])
    }

    @Test("an empty existing list deletes nothing")
    func emptyExistingDeletesNothing() {
        let result = DictationHistoryPruning.entriesToDelete(existing: [], activeEntryId: nil, maxEntries: 100)

        #expect(result.isEmpty)
    }

    @Test("orphans are deleted even when there are no complete entries at all")
    func allOrphansWithNoCompleteEntriesAreAllDeleted() {
        let existing = [
            Self.entry("orphan-1", offset: 0, isComplete: false),
            Self.entry("orphan-2", offset: 1, isComplete: false),
        ]

        let result = DictationHistoryPruning.entriesToDelete(existing: existing, activeEntryId: nil, maxEntries: 100)

        #expect(result == ["orphan-1", "orphan-2"])
    }

    @Test("orphans do not count toward maxEntries: a complete count under the limit plus orphans deletes only the orphans")
    func orphansDoNotCountTowardMaxEntries() {
        let existing = [
            Self.entry("orphan-1", offset: 0, isComplete: false),
            Self.entry("a", offset: 1),
            Self.entry("b", offset: 2),
        ]

        let result = DictationHistoryPruning.entriesToDelete(existing: existing, activeEntryId: nil, maxEntries: 2)

        #expect(result == ["orphan-1"])
    }

    @Test("orphans and overflow are both deleted together, orphans first then oldest-first overflow among the complete entries only")
    func orphansAndOverflowAreDeletedTogether() {
        let existing = [
            Self.entry("orphan-1", offset: 0, isComplete: false),
            Self.entry("a", offset: 1),
            Self.entry("b", offset: 2),
            Self.entry("orphan-2", offset: 3, isComplete: false),
            Self.entry("c", offset: 4),
            Self.entry("d", offset: 5),
        ]

        let result = DictationHistoryPruning.entriesToDelete(existing: existing, activeEntryId: nil, maxEntries: 2)

        #expect(result == ["orphan-1", "orphan-2", "a", "b"])
    }

    @Test("overflow selection is oldest-first by recordedAt regardless of the input array's order")
    func overflowSelectionIgnoresInputOrder() {
        let existing = [
            Self.entry("d", offset: 3),
            Self.entry("a", offset: 0),
            Self.entry("c", offset: 2),
            Self.entry("b", offset: 1),
        ]

        let result = DictationHistoryPruning.entriesToDelete(existing: existing, activeEntryId: nil, maxEntries: 2)

        #expect(result == ["a", "b"])
    }
}
