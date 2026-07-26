import Foundation

// MARK: - EntryIdNaming

/// Shared folder-name/entry-id generator for the two "one folder per timestamped entry" stores in
/// Kikimi: `SessionStore.createDraftSession(basedOn:)` (`SessionStore.swift`) and
/// `DictationHistoryStore.beginEntry(startedAt:)` (`docs/design/29-dictation-history.md` §3.1/§5.1,
/// not yet implemented). Both mint an id of the shape
/// `"{ISO8601 start time (UTC, colons hyphenated)}_{8-char lowercase hex short UUID}"` and use that
/// same string as both the on-disk directory name and the entry's logical id -- this type is the
/// single place that format is generated, so the two stores can never drift apart (design 29 §3.1:
/// "同関数は private のため、命名ロジックを共有ヘルパに抽出して両者で使う").
///
/// The UTC timestamp embedded here is meant to always be reconstructable from -- and consistent
/// with -- the ISO8601(UTC) timestamp the caller separately persists in its own metadata file
/// (`SessionMeta.startedAt` in `meta.json`, `recorded_at` in `entry.json` per design 29 §3.2/§5.2).
/// `EntryIdNamingTests` pins this round-trip so the two never silently diverge (e.g. one side
/// switching to local time).
enum EntryIdNaming {
    /// Generates a new id for `date`, which callers pass as their own "recorded/started at" instant
    /// so the id's embedded timestamp matches the metadata file's timestamp exactly.
    static func makeId(for date: Date) -> String {
        let timestamp = utcTimestampFormatter.string(from: date)
        let shortId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        return "\(timestamp)_\(shortId)"
    }

    /// Recovers the (whole-second-truncated) UTC instant embedded in an id `makeId(for:)` minted, or
    /// `nil` if `id` doesn't match the expected shape. `DictationHistoryStore`'s prune step
    /// (`docs/design/29-dictation-history.md` §5.2) uses this to derive each entry's `recordedAt`
    /// straight from its folder name, so `finalize(handle:entry:maxEntries:)` never has to decode
    /// every entry's `entry.json` just to sort candidates by recency.
    static func recordedAt(fromId id: String) -> Date? {
        guard let underscoreIndex = id.lastIndex(of: "_") else { return nil }
        let timestampPortion = String(id[id.startIndex..<underscoreIndex])
        return utcTimestampFormatter.date(from: timestampPortion)
    }

    /// `yyyy-MM-dd'T'HH-mm-ss` in UTC -- the ISO8601 date/time portion with `:` replaced by `-` so the
    /// result is a safe single path component on every filesystem Kikimi targets.
    private static var utcTimestampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter
    }
}
