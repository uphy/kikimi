import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `MeetingProfileStore` (`Kikimi/Profiles/MeetingProfileStore.swift`,
/// `docs/design/41-meeting-profiles.md` §3.2/§8/§9). Every test is DI'd against a temporary
/// `directoryURL`, mirroring `WatcherLibraryTests.swift`'s own directory-scanning-store convention.
@Suite("MeetingProfileStore")
struct MeetingProfileStoreTests {
    // MARK: - Fixtures

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func profileDirectory(_ directory: URL, id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    /// Writes a `profile.yaml` directly to disk (bypassing `save(_:overwrite:)`), for fixtures that
    /// need a specific/broken on-disk shape rather than whatever `save` itself would produce.
    private func writeRawProfileYAML(_ yaml: String, id: String, in directory: URL) throws {
        let dir = profileDirectory(directory, id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try yaml.write(to: dir.appendingPathComponent("profile.yaml"), atomically: true, encoding: .utf8)
    }

    private func writeFile(_ text: String, name: String, id: String, in directory: URL) throws {
        let dir = profileDirectory(directory, id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // `save(_:overwrite:)`'s write-failure-injection test below (§3.2, §8 #8) uses a real
    // `FileManager` with the profiles directory made read-only (`RefinementQueueTests.swift`'s own
    // `0o555`-permission injection pattern) rather than a `FileManager` subclass overriding
    // `replaceItemAt(_:withItemAt:...)`: that particular method is a Swift-overlay convenience
    // declared in a `FileManager` extension, so subclasses cannot override it at all (it has no
    // class-side dispatch slot to intercept) -- attempting to do so is a compile error, not a
    // runtime no-op.

    // MARK: - list(): sorting

    @Test("list() sorts profiles by name, Japanese-aware (localizedStandardCompare)")
    func listSortsByNameJapaneseAware() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeRawProfileYAML("name: 週次定例\n", id: "weekly", in: directory)
        try writeRawProfileYAML("name: あさかい\n", id: "morning", in: directory)
        try writeRawProfileYAML("name: いちおん会議\n", id: "one-on-one", in: directory)

        let store = MeetingProfileStore(directoryURL: directory)
        let names = await store.list().map(\.name)

        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(Set(names) == ["週次定例", "あさかい", "いちおん会議"])
    }

    // MARK: - list(): exclusions (§8 #1/#2)

    @Test("list() returns [] (no crash) when the profiles directory does not exist yet")
    func listReturnsEmptyWhenDirectoryMissing() async throws {
        let directory = makeTempDirectory().appendingPathComponent("does-not-exist", isDirectory: true)
        let store = MeetingProfileStore(directoryURL: directory)

        #expect(await store.list().isEmpty)
    }

    @Test("list() skips a directory with no profile.yaml at all")
    func listSkipsDirectoryWithoutManifest() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(
            at: profileDirectory(directory, id: "empty-dir"), withIntermediateDirectories: true
        )
        try writeRawProfileYAML("name: 有効なプロファイル\n", id: "valid", in: directory)

        let store = MeetingProfileStore(directoryURL: directory)
        let profiles = await store.list()

        #expect(profiles.map(\.id) == ["valid"])
    }

    @Test("list() skips a directory whose profile.yaml fails to decode")
    func listSkipsDirectoryWithBrokenManifest() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // `name` is required (§2.2); this manifest omits it entirely.
        try writeRawProfileYAML("description: 名前が無い\n", id: "broken", in: directory)
        try writeRawProfileYAML("name: 有効なプロファイル\n", id: "valid", in: directory)

        let store = MeetingProfileStore(directoryURL: directory)
        let profiles = await store.list()

        #expect(profiles.map(\.id) == ["valid"])
    }

    @Test("list() skips a directory whose name is not a valid profile id")
    func listSkipsDirectoryWithInvalidId() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeRawProfileYAML("name: 不正なID\n", id: "invalid id!", in: directory)
        try writeRawProfileYAML("name: 有効なプロファイル\n", id: "valid", in: directory)

        let store = MeetingProfileStore(directoryURL: directory)
        let profiles = await store.list()

        #expect(profiles.map(\.id) == ["valid"])
    }

    // MARK: - read(id:): id validation / missing / broken

    @Test("read(id:) returns nil for an id that fails MeetingProfileIdValidation")
    func readReturnsNilForInvalidId() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        #expect(await store.read(id: "bad id!") == nil)
        #expect(await store.read(id: "") == nil)
        #expect(await store.read(id: "a/b") == nil)
    }

    @Test("read(id:) returns nil when the profile directory does not exist")
    func readReturnsNilWhenDirectoryMissing() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        #expect(await store.read(id: "nonexistent") == nil)
    }

    @Test("read(id:) returns nil when profile.yaml fails to decode")
    func readReturnsNilForBrokenManifest() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRawProfileYAML("description: 名前が無い\n", id: "broken", in: directory)
        let store = MeetingProfileStore(directoryURL: directory)

        #expect(await store.read(id: "broken") == nil)
    }

    // MARK: - read(id:): field decoding, including the enabled_watchers key-presence distinction (§2.2)

    @Test("read(id:) decodes name/description and reports hasContext/hasSummaryTemplate from file presence")
    func readDecodesBasicFieldsAndFilePresence() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeRawProfileYAML(
            "name: デイリースクラム\ndescription: 毎朝のスクラム\n", id: "daily-scrum", in: directory
        )
        try writeFile("# context", name: "context.md", id: "daily-scrum", in: directory)
        // No summary_template.md written for this profile.

        let store = MeetingProfileStore(directoryURL: directory)
        let profile = try #require(await store.read(id: "daily-scrum"))

        #expect(profile.id == "daily-scrum")
        #expect(profile.name == "デイリースクラム")
        #expect(profile.description == "毎朝のスクラム")
        #expect(profile.hasContext == true)
        #expect(profile.hasSummaryTemplate == false)
    }

    @Test("read(id:) decodes an absent enabled_watchers key as nil (fall back to default_watchers.yaml)")
    func readDecodesAbsentEnabledWatchersAsNil() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRawProfileYAML("name: プロファイル\n", id: "p", in: directory)
        let store = MeetingProfileStore(directoryURL: directory)

        let profile = try #require(await store.read(id: "p"))
        #expect(profile.enabledWatchers == nil)
    }

    @Test("read(id:) decodes an explicit empty enabled_watchers list as [] (distinct from nil, §2.2)")
    func readDecodesEmptyEnabledWatchersAsEmptyArray() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRawProfileYAML("name: プロファイル\nenabled_watchers: []\n", id: "p", in: directory)
        let store = MeetingProfileStore(directoryURL: directory)

        let profile = try #require(await store.read(id: "p"))
        #expect(profile.enabledWatchers == [])
        #expect(profile.enabledWatchers != nil)
    }

    @Test("read(id:) decodes a populated enabled_watchers list, and participant_ids likewise")
    func readDecodesPopulatedListsAndParticipantIds() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRawProfileYAML(
            """
            name: プロファイル
            enabled_watchers:
              - pre-check
              - action-items
            participant_ids:
              - spk_abc123
            """,
            id: "p", in: directory
        )
        let store = MeetingProfileStore(directoryURL: directory)

        let profile = try #require(await store.read(id: "p"))
        #expect(profile.enabledWatchers == ["pre-check", "action-items"])
        #expect(profile.participantIds == ["spk_abc123"])
    }

    // MARK: - readContext(id:) / readSummaryTemplate(id:)

    @Test("readContext/readSummaryTemplate return nil for an invalid id or an absent file, and the text when present")
    func readContextAndSummaryTemplate() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRawProfileYAML("name: プロファイル\n", id: "p", in: directory)
        try writeFile("# context body", name: "context.md", id: "p", in: directory)

        let store = MeetingProfileStore(directoryURL: directory)

        #expect(await store.readContext(id: "p") == "# context body")
        #expect(await store.readSummaryTemplate(id: "p") == nil)
        #expect(await store.readContext(id: "bad id!") == nil)
        #expect(await store.readContext(id: "no-such-profile") == nil)
    }

    // MARK: - save(_:overwrite:): new profile

    @Test("save(_:overwrite: false) creates a new profile, writing only the non-nil fields")
    func saveCreatesNewProfile() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        let draft = MeetingProfileDraft(
            id: "daily-scrum",
            name: "デイリースクラム",
            description: "毎朝のスクラム",
            context: "# context",
            summaryTemplate: nil,
            enabledWatchers: ["pre-check"],
            participantIds: nil
        )
        try await store.save(draft, overwrite: false)

        let profile = try #require(await store.read(id: "daily-scrum"))
        #expect(profile.name == "デイリースクラム")
        #expect(profile.description == "毎朝のスクラム")
        #expect(profile.enabledWatchers == ["pre-check"])
        #expect(profile.participantIds == nil)
        #expect(profile.hasContext == true)
        #expect(profile.hasSummaryTemplate == false)
        #expect(await store.readContext(id: "daily-scrum") == "# context")
    }

    @Test("save(_:overwrite: false) throws when a profile with the same id already exists")
    func saveWithoutOverwriteThrowsOnCollision() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        let draft = MeetingProfileDraft(
            id: "p", name: "最初", description: nil, context: nil, summaryTemplate: nil,
            enabledWatchers: nil, participantIds: nil
        )
        try await store.save(draft, overwrite: false)

        let secondDraft = MeetingProfileDraft(
            id: "p", name: "衝突", description: nil, context: nil, summaryTemplate: nil,
            enabledWatchers: nil, participantIds: nil
        )
        await #expect(throws: MeetingProfileStoreError.self) {
            try await store.save(secondDraft, overwrite: false)
        }

        // The original profile must be untouched by the rejected collision.
        let profile = try #require(await store.read(id: "p"))
        #expect(profile.name == "最初")
    }

    @Test("save(_:overwrite:) throws .invalidId for a draft.id that fails MeetingProfileIdValidation")
    func saveThrowsInvalidIdForBadId() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        let draft = MeetingProfileDraft(
            id: "bad id!", name: "x", description: nil, context: nil, summaryTemplate: nil,
            enabledWatchers: nil, participantIds: nil
        )
        await #expect(throws: MeetingProfileStoreError.invalidId("bad id!")) {
            try await store.save(draft, overwrite: false)
        }
    }

    // MARK: - save(_:overwrite: true): carry-over semantics for context/summaryTemplate

    @Test("save(_:overwrite: true) with a nil context/summaryTemplate leaves the existing files untouched")
    func overwriteWithNilFieldsPreservesExistingContentFiles() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        let original = MeetingProfileDraft(
            id: "p", name: "最初", description: nil, context: "# A", summaryTemplate: "# T",
            enabledWatchers: nil, participantIds: nil
        )
        try await store.save(original, overwrite: false)

        // Overwrite with context/summaryTemplate omitted (nil): existing files carry over unchanged.
        let update = MeetingProfileDraft(
            id: "p", name: "更新後", description: nil, context: nil, summaryTemplate: nil,
            enabledWatchers: nil, participantIds: nil
        )
        try await store.save(update, overwrite: true)

        let profile = try #require(await store.read(id: "p"))
        #expect(profile.name == "更新後")
        #expect(profile.hasContext == true)
        #expect(profile.hasSummaryTemplate == true)
        #expect(await store.readContext(id: "p") == "# A")
        #expect(await store.readSummaryTemplate(id: "p") == "# T")
    }

    @Test("save(_:overwrite: true) with a non-nil context replaces the existing file's content")
    func overwriteWithNonNilFieldReplacesContent() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        let original = MeetingProfileDraft(
            id: "p", name: "最初", description: nil, context: "# A", summaryTemplate: nil,
            enabledWatchers: nil, participantIds: nil
        )
        try await store.save(original, overwrite: false)

        let update = MeetingProfileDraft(
            id: "p", name: "最初", description: nil, context: "# B", summaryTemplate: nil,
            enabledWatchers: nil, participantIds: nil
        )
        try await store.save(update, overwrite: true)

        #expect(await store.readContext(id: "p") == "# B")
    }

    @Test("save(_:overwrite: true) with nil enabled_watchers/participant_ids carries over the existing manifest values, same as description (save(_:overwrite:)'s own doc comment)")
    func overwriteWithNilManifestListsCarriesOverExistingValues() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        let original = MeetingProfileDraft(
            id: "p", name: "最初", description: nil, context: nil, summaryTemplate: nil,
            enabledWatchers: ["pre-check"], participantIds: ["spk_1"]
        )
        try await store.save(original, overwrite: false)

        // A nil `enabledWatchers`/`participantIds` on overwrite is "don't touch this", exactly like
        // `description`/`context`/`summaryTemplate` (`save(_:overwrite:)`'s own doc comment: "A nil
        // draft.description / draft.enabledWatchers / draft.participantIds / draft.context /
        // draft.summaryTemplate uniformly means 'don't touch this'"): the existing manifest's values
        // survive the overwrite unchanged.
        let update = MeetingProfileDraft(
            id: "p", name: "最初", description: nil, context: nil, summaryTemplate: nil,
            enabledWatchers: nil, participantIds: nil
        )
        try await store.save(update, overwrite: true)

        let profile = try #require(await store.read(id: "p"))
        #expect(profile.enabledWatchers == ["pre-check"])
        #expect(profile.participantIds == ["spk_1"])
    }

    @Test("save(_:overwrite: true) with a non-nil enabled_watchers/participant_ids replaces the existing manifest values wholesale, including clearing to an explicit empty list")
    func overwriteWithNonNilManifestListsReplacesExistingValues() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        let original = MeetingProfileDraft(
            id: "p", name: "最初", description: nil, context: nil, summaryTemplate: nil,
            enabledWatchers: ["pre-check"], participantIds: ["spk_1"]
        )
        try await store.save(original, overwrite: false)

        // A non-nil value always replaces what was there before, whether the new value is populated
        // or an explicit empty list (still non-nil -- distinct from omitting the field entirely,
        // §2.2's "キーの有無で意味が変わる").
        let update = MeetingProfileDraft(
            id: "p", name: "最初", description: nil, context: nil, summaryTemplate: nil,
            enabledWatchers: [], participantIds: ["spk_2"]
        )
        try await store.save(update, overwrite: true)

        let profile = try #require(await store.read(id: "p"))
        #expect(profile.enabledWatchers == [])
        #expect(profile.participantIds == ["spk_2"])
    }

    // MARK: - save(_:overwrite:): write-failure injection leaves the existing profile untouched (§8 #8)

    @Test("save(_:overwrite: true) leaves the existing profile completely untouched when a write step of the overwrite attempt fails")
    func failedOverwriteLeavesExistingProfileUntouched() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MeetingProfileStore(directoryURL: directory)
        let original = MeetingProfileDraft(
            id: "p", name: "最初", description: "元の説明", context: "# original", summaryTemplate: nil,
            enabledWatchers: ["pre-check"], participantIds: nil
        )
        try await store.save(original, overwrite: false)

        let update = MeetingProfileDraft(
            id: "p", name: "更新後", description: "新しい説明", context: "# updated", summaryTemplate: nil,
            enabledWatchers: ["action-items"], participantIds: nil
        )

        // Make `directory` read-only so `save(_:overwrite:)` cannot create its sibling temp-staging
        // directory at all -- a real I/O failure partway through the write, before the existing
        // profile at `directory/p/` is ever touched (§8 #8). Restored before this test does anything
        // else with `directory`, including its own cleanup `defer` above.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        await #expect(throws: MeetingProfileStoreError.self) {
            try await store.save(update, overwrite: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        // The pre-existing profile must be entirely unaffected by the failed overwrite attempt.
        let profile = try #require(await store.read(id: "p"))
        #expect(profile.name == "最初")
        #expect(profile.description == "元の説明")
        #expect(profile.enabledWatchers == ["pre-check"])
        #expect(await store.readContext(id: "p") == "# original")

        // No leftover temp staging directory should remain in the profiles directory.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    // MARK: - delete(id:)

    @Test("delete(id:) removes the profile directory entirely")
    func deleteRemovesDirectory() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        let draft = MeetingProfileDraft(
            id: "p", name: "x", description: nil, context: "# c", summaryTemplate: nil,
            enabledWatchers: nil, participantIds: nil
        )
        try await store.save(draft, overwrite: false)
        #expect(await store.read(id: "p") != nil)

        try await store.delete(id: "p")

        #expect(await store.read(id: "p") == nil)
        #expect(!FileManager.default.fileExists(atPath: profileDirectory(directory, id: "p").path))
    }

    @Test("delete(id:) throws .notFound for an invalid id or a nonexistent profile")
    func deleteThrowsNotFoundForMissingOrInvalidId() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        await #expect(throws: MeetingProfileStoreError.notFound("bad id!")) {
            try await store.delete(id: "bad id!")
        }
        await #expect(throws: MeetingProfileStoreError.notFound("nonexistent")) {
            try await store.delete(id: "nonexistent")
        }
    }

    // MARK: - rename(id:newName:)

    @Test("rename(id:newName:) updates only the name, preserving description/enabled_watchers/participant_ids")
    func renameUpdatesOnlyName() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        let draft = MeetingProfileDraft(
            id: "p", name: "旧名", description: "説明", context: nil, summaryTemplate: nil,
            enabledWatchers: ["pre-check"], participantIds: ["spk_1"]
        )
        try await store.save(draft, overwrite: false)

        try await store.rename(id: "p", newName: "新名")

        let profile = try #require(await store.read(id: "p"))
        #expect(profile.name == "新名")
        #expect(profile.description == "説明")
        #expect(profile.enabledWatchers == ["pre-check"])
        #expect(profile.participantIds == ["spk_1"])
    }

    @Test("rename(id:newName:) throws .notFound for an invalid id or a nonexistent profile")
    func renameThrowsNotFoundForMissingOrInvalidId() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingProfileStore(directoryURL: directory)

        await #expect(throws: MeetingProfileStoreError.notFound("bad id!")) {
            try await store.rename(id: "bad id!", newName: "x")
        }
        await #expect(throws: MeetingProfileStoreError.notFound("nonexistent")) {
            try await store.rename(id: "nonexistent", newName: "x")
        }
    }
}
