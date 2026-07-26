import Foundation

// MARK: - DictationHistoryPruning

/// Pure decision logic for `DictationHistoryStore.finalize`'s prune step
/// (`docs/design/29-dictation-history.md` section 5.2). No file I/O of its own -- the store derives
/// `existing` from folder names + `entry.json` presence and passes it in here.
enum DictationHistoryPruning {
    /// Returns the ids to delete: every orphan (`isComplete == false`, i.e. a folder without a
    /// written `entry.json`) unconditionally, plus the oldest-first overflow beyond `maxEntries`
    /// among the complete entries. The active entry id (in-flight `beginEntry`/`finalize`, section
    /// 5.1) is always excluded from both categories.
    ///
    /// Precondition: `maxEntries >= 1`. Normalizing invalid config values is the config decode
    /// layer's responsibility (section 7.1), not this function's.
    static func entriesToDelete(
        existing: [(id: String, recordedAt: Date, isComplete: Bool)],
        activeEntryId: String?,
        maxEntries: Int
    ) -> [String] {
        precondition(maxEntries >= 1, "maxEntries must be >= 1; invalid config values must be normalized before this call")

        let candidates = existing.filter { $0.id != activeEntryId }

        let orphanIds = candidates.filter { !$0.isComplete }.map(\.id)

        let complete = candidates.filter(\.isComplete)
        let overflowCount = complete.count - maxEntries
        let overflowIds: [String]
        if overflowCount > 0 {
            overflowIds = complete
                .sorted { $0.recordedAt < $1.recordedAt }
                .prefix(overflowCount)
                .map(\.id)
        } else {
            overflowIds = []
        }

        return orphanIds + overflowIds
    }
}
