import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for the shared `EntryIdNaming.makeId(for:)` helper extracted from
/// `SessionStore`'s formerly-private `makeSessionId(for:)` (`docs/design/29-dictation-history.md`
/// §3.1). Pins the exact `"{ISO8601 start time (UTC, colons hyphenated)}_{8-char short UUID}"`
/// shape and, crucially, that the embedded timestamp round-trips to the same UTC instant a
/// metadata file's ISO8601(UTC) field would record for it -- design 29 §3.1/§5.2 depend on this
/// round trip to reconstruct `recorded_at` from the folder name alone.
@Suite("EntryIdNaming")
struct EntryIdNamingTests {
    /// `2026-07-10T09:15:32Z` -- an arbitrary, easy-to-eyeball fixed instant used across this suite.
    private static let fixedDate = ISO8601DateFormatter().date(from: "2026-07-10T09:15:32Z")!

    // MARK: - Shape

    @Test("makeId(for:) produces \"{yyyy-MM-dd'T'HH-mm-ss}_{8-char lowercase hex}\"")
    func matchesExpectedShape() {
        let id = EntryIdNaming.makeId(for: Self.fixedDate)
        let pattern = #/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}_[0-9a-f]{8}$/#
        #expect(id.wholeMatch(of: pattern) != nil, "unexpected id shape: \(id)")
    }

    @Test("the timestamp portion is UTC regardless of the current/system time zone")
    func timestampPortionIsUTC() {
        let id = EntryIdNaming.makeId(for: Self.fixedDate)
        let timestampPortion = String(id.dropLast(9)) // drop "_" + 8 hex chars
        #expect(timestampPortion == "2026-07-10T09-15-32")
    }

    @Test("two ids minted for the same instant get different short-UUID suffixes")
    func suffixVariesAcrossCalls() {
        let first = EntryIdNaming.makeId(for: Self.fixedDate)
        let second = EntryIdNaming.makeId(for: Self.fixedDate)
        #expect(first != second)
    }

    // MARK: - Round trip with an ISO8601(UTC) metadata timestamp (design 29 §3.1/§5.2)

    /// Fixes the contract design 29 §3.1 requires: the folder name's timestamp, once you swap the
    /// hyphens back for colons and append "Z", must equal the *exact same instant* an ISO8601(UTC)
    /// metadata field (`meta.json`'s `startedAt`, `entry.json`'s `recorded_at`) would encode for the
    /// `Date` passed to `makeId(for:)`. This is what makes "recover `recorded_at` from the folder
    /// name" (§5.2) sound.
    @Test("the folder-name timestamp round-trips to the same instant as an ISO8601(UTC) metadata field, for a range of dates")
    func roundTripsWithISO8601UTCMetadataTimestamp() throws {
        let iso8601 = ISO8601DateFormatter()
        let dates = [
            Self.fixedDate,
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(),
        ]

        for date in dates {
            let id = EntryIdNaming.makeId(for: date)
            let timestampPortion = String(id.dropLast(9))

            // What an entry.json/meta.json ISO8601(UTC) field would store for the same `date`,
            // truncated to whole seconds the same way `makeId(for:)`'s formatter does.
            let expectedMetadataTimestamp = iso8601.string(from: date)
            let expectedFolderTimestamp = String(expectedMetadataTimestamp.dropLast()) // drop trailing "Z"
                .replacingOccurrences(of: ":", with: "-")

            #expect(timestampPortion == expectedFolderTimestamp, "mismatch for \(date)")

            // And the reverse direction: reparsing the folder-name portion as UTC recovers a Date
            // that, once reformatted as ISO8601(UTC), matches what the metadata file would have
            // stored (i.e. no drift beyond the initial whole-second truncation).
            let folderFormatter = DateFormatter()
            folderFormatter.calendar = Calendar(identifier: .gregorian)
            folderFormatter.locale = Locale(identifier: "en_US_POSIX")
            folderFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            folderFormatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            let recoveredDate = try #require(folderFormatter.date(from: timestampPortion))
            #expect(iso8601.string(from: recoveredDate) == expectedMetadataTimestamp)
        }
    }

    // MARK: - recordedAt(fromId:)

    /// The direct inverse of `makeId(for:)`: for any id `makeId` mints, `recordedAt(fromId:)` must
    /// recover the same whole-second-truncated instant. `DictationHistoryStore`'s prune step (design
    /// 29 §5.2) relies on this to sort candidates by recency straight from folder names.
    @Test("recordedAt(fromId:) recovers the whole-second-truncated instant makeId(for:) embedded")
    func recordedAtRecoversInstantFromMintedId() throws {
        let dates = [
            Self.fixedDate,
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 1_700_000_000),
        ]

        for date in dates {
            let id = EntryIdNaming.makeId(for: date)
            let recovered = try #require(EntryIdNaming.recordedAt(fromId: id), "expected a Date for id \(id)")

            // Whole-second truncation, same as makeId(for:)'s formatter performs.
            let expectedSeconds = date.timeIntervalSince1970.rounded(.towardZero)
            #expect(recovered.timeIntervalSince1970 == expectedSeconds, "mismatch for \(date)")
        }
    }

    @Test("recordedAt(fromId:) returns nil for an id with no underscore separator")
    func recordedAtReturnsNilWithoutUnderscore() {
        #expect(EntryIdNaming.recordedAt(fromId: "2026-07-10T09-15-32") == nil)
    }

    @Test("recordedAt(fromId:) returns nil for an id whose timestamp portion doesn't parse")
    func recordedAtReturnsNilForUnparseableTimestamp() {
        #expect(EntryIdNaming.recordedAt(fromId: "not-a-timestamp_abcd1234") == nil)
    }

    @Test("recordedAt(fromId:) returns nil for an empty string")
    func recordedAtReturnsNilForEmptyString() {
        #expect(EntryIdNaming.recordedAt(fromId: "") == nil)
    }

    @Test("recordedAt(fromId:) uses the *last* underscore, tolerating extra underscores before the suffix")
    func recordedAtUsesLastUnderscore() {
        // The 8-char hex suffix never itself contains an underscore, but this pins that
        // `recordedAt(fromId:)` splits on the *last* "_" rather than the first, in case the
        // timestamp portion were ever to contain one.
        let id = "2026-07-10T09-15-32_extra_abcd1234"
        let recovered = EntryIdNaming.recordedAt(fromId: id)
        #expect(recovered == nil, "timestamp portion \"2026-07-10T09-15-32_extra\" should fail to parse")
    }

    // MARK: - SessionStore integration (behavior-preserving refactor)

    /// `SessionStore.createDraftSession(basedOn:)` now delegates to `EntryIdNaming.makeId(for:)`
    /// instead of its own private `makeSessionId(for:)`; this pins that the session id it produces
    /// still round-trips to `meta.createdAt` exactly as before the extraction.
    @Test("SessionStore.createDraftSession's generated id round-trips to meta.createdAt via ISO8601(UTC)")
    func sessionStoreGeneratedIdRoundTripsToMetaCreatedAt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntryIdNamingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(
            sessionsRootDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            defaultContextFileURL: root.appendingPathComponent("missing-context.md"),
            defaultSummaryTemplateFileURL: root.appendingPathComponent("missing-template.md"),
            defaultEnabledWatchersFileURL: root.appendingPathComponent("missing-enabled.yaml")
        )

        let meta = try await store.createDraftSession()

        let pattern = #/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}_[0-9a-f]{8}$/#
        #expect(meta.id.wholeMatch(of: pattern) != nil, "unexpected id shape: \(meta.id)")

        let timestampPortion = String(meta.id.dropLast(9))
        let expectedFolderTimestamp = String(ISO8601DateFormatter().string(from: meta.createdAt).dropLast())
            .replacingOccurrences(of: ":", with: "-")
        #expect(timestampPortion == expectedFolderTimestamp)
    }
}
