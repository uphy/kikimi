import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `SessionStore.createDraftSession(seed:)`'s `DraftSeed` resolution
/// (`docs/design/41-meeting-profiles.md` §3.1/§4/§8 #3), on top of the pre-existing `.basedOn`/`.none`
/// coverage `SessionStoreTests.swift`/`SessionStoreDefaultsTests.swift` already have. This file adds:
/// the `.profile` seed's 4-file resolution chain (§4's table, one test per row), the unknown-profile-id
/// soft-fallback (`appliedSeed == .profileFallback(requestedId:)`, `meta.profileId` left unrecorded),
/// a `.profile` success-path regression check (`appliedSeed == .profile(id:)`, `meta.profileId ==
/// id`), the pre-existing `.basedOn`/`.none` -> `appliedSeed` mapping (regression), and the
/// `createDraftSession(basedOn:)` compatibility wrapper's delegation to `createDraftSession(seed:)`.
///
/// Every test is DI'd against temporary `sessionsRootDirectory`/`profilesDirectoryURL`/default-file
/// directories, mirroring `SessionStoreDefaultsTests.swift`'s own convention.
@Suite("SessionStore.createDraftSession(seed:) (DraftSeed resolution, design 41)")
struct SessionStoreDraftSeedTests {
    // MARK: - Fixtures

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreDraftSeedTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Same shape as `SessionStoreDefaultsTests.makeStore(...)`: every default/profiles location
    /// points at a nonexistent path under `root` unless overridden, so every fallback rung is
    /// exercised deliberately, not accidentally.
    private func makeStore(
        root: URL,
        profilesDirectoryURL: URL? = nil,
        defaultContextFileURL: URL? = nil,
        defaultSummaryTemplateFileURL: URL? = nil,
        defaultEnabledWatchersFileURL: URL? = nil
    ) -> (store: SessionStore, sessionsRoot: URL) {
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let store = SessionStore(
            sessionsRootDirectory: sessionsRoot,
            defaultContextFileURL: defaultContextFileURL ?? root.appendingPathComponent("missing-context.md"),
            defaultSummaryTemplateFileURL: defaultSummaryTemplateFileURL ?? root.appendingPathComponent("missing-template.md"),
            defaultEnabledWatchersFileURL: defaultEnabledWatchersFileURL ?? root.appendingPathComponent("missing-enabled.yaml"),
            profilesDirectoryURL: profilesDirectoryURL ?? root.appendingPathComponent("missing-profiles", isDirectory: true)
        )
        return (store, sessionsRoot)
    }

    private func sessionDirectory(root: URL, sessionId: String) -> URL {
        root.appendingPathComponent(sessionId, isDirectory: true)
    }

    /// Writes `profilesDirectoryURL/<id>/profile.yaml` (plus optional context.md/summary_template.md)
    /// directly to disk, bypassing `MeetingProfileStore` -- this suite only needs a fixture on disk,
    /// not the store's own write path (that is `MeetingProfileStoreTests.swift`'s job).
    private func writeProfile(
        id: String,
        in profilesDirectoryURL: URL,
        name: String = "テストプロファイル",
        context: String? = nil,
        summaryTemplate: String? = nil,
        enabledWatchersYAML: String? = nil,
        participantIdsYAML: String? = nil
    ) throws {
        let profileDir = profilesDirectoryURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        var manifest = "name: \(name)\n"
        if let enabledWatchersYAML {
            // An empty string means "key present, explicitly empty list" (§2.2) -- `key:` alone
            // followed by nothing parses as YAML null, not `[]`, so this needs the inline-flow form.
            manifest += enabledWatchersYAML.isEmpty ? "enabled_watchers: []\n" : "enabled_watchers:\n\(enabledWatchersYAML)\n"
        }
        if let participantIdsYAML {
            manifest += participantIdsYAML.isEmpty ? "participant_ids: []\n" : "participant_ids:\n\(participantIdsYAML)\n"
        }
        try manifest.write(to: profileDir.appendingPathComponent("profile.yaml"), atomically: true, encoding: .utf8)

        if let context {
            try context.write(to: profileDir.appendingPathComponent("context.md"), atomically: true, encoding: .utf8)
        }
        if let summaryTemplate {
            try summaryTemplate.write(to: profileDir.appendingPathComponent("summary_template.md"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - .profile seed: context.md (§4 table row 1)

    @Test(".profile seed reads context.md from the profile when present")
    func profileSeedReadsOwnContext() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL, context: "# プロファイル固有のメモ")

        let (store, _) = makeStore(root: root, profilesDirectoryURL: profilesDirectoryURL)
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))
        let handle = try await store.openSession(result.meta.id)

        #expect(await handle.readContext() == "# プロファイル固有のメモ")
    }

    @Test(".profile seed falls back to the global default context.md when the profile has none")
    func profileSeedFallsBackToGlobalDefaultContext() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL) // no context.md

        let globalDefaultContext = root.appendingPathComponent("global-context.md")
        try "# 全体デフォルトのメモ".write(to: globalDefaultContext, atomically: true, encoding: .utf8)

        let (store, _) = makeStore(root: root, profilesDirectoryURL: profilesDirectoryURL, defaultContextFileURL: globalDefaultContext)
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))
        let handle = try await store.openSession(result.meta.id)

        #expect(await handle.readContext() == "# 全体デフォルトのメモ")
    }

    @Test(".profile seed falls all the way through to an empty context.md when nothing is readable")
    func profileSeedFallsBackToEmptyContext() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL)

        let (store, _) = makeStore(root: root, profilesDirectoryURL: profilesDirectoryURL)
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))
        let handle = try await store.openSession(result.meta.id)

        #expect(await handle.readContext() == "")
    }

    // MARK: - .profile seed: summary_template.md (§4 table row 2)

    @Test(".profile seed reads summary_template.md from the profile when present")
    func profileSeedReadsOwnSummaryTemplate() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL, summaryTemplate: "# {{title}}\nプロファイル固有テンプレート")

        let (store, _) = makeStore(root: root, profilesDirectoryURL: profilesDirectoryURL)
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))
        let handle = try await store.openSession(result.meta.id)

        #expect(await handle.readSummaryTemplate() == "# {{title}}\nプロファイル固有テンプレート")
    }

    @Test(".profile seed falls back to the global default summary_template.md when the profile has none")
    func profileSeedFallsBackToGlobalDefaultTemplate() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL)

        let globalDefaultTemplate = root.appendingPathComponent("global-template.md")
        try "# {{title}}\n全体デフォルトテンプレート".write(to: globalDefaultTemplate, atomically: true, encoding: .utf8)

        let (store, _) = makeStore(
            root: root, profilesDirectoryURL: profilesDirectoryURL, defaultSummaryTemplateFileURL: globalDefaultTemplate
        )
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))
        let handle = try await store.openSession(result.meta.id)

        #expect(await handle.readSummaryTemplate() == "# {{title}}\n全体デフォルトテンプレート")
    }

    @Test(".profile seed falls all the way through to the built-in default summary template")
    func profileSeedFallsBackToBuiltInTemplate() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL)

        let (store, _) = makeStore(root: root, profilesDirectoryURL: profilesDirectoryURL)
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))
        let handle = try await store.openSession(result.meta.id)

        #expect(await handle.readSummaryTemplate() == SessionStore.builtInDefaultSummaryTemplate)
    }

    // MARK: - .profile seed: watchers/enabled.yaml (§4 table row 3)

    @Test(".profile seed honors an explicit empty enabled_watchers key (enable nothing), not falling back to default_watchers.yaml")
    func profileSeedHonorsExplicitEmptyEnabledWatchers() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL, enabledWatchersYAML: "")

        let defaultEnabledFile = root.appendingPathComponent("default_watchers.yaml")
        try "enabled:\n  - pre-check\n".write(to: defaultEnabledFile, atomically: true, encoding: .utf8)

        let (store, _) = makeStore(
            root: root, profilesDirectoryURL: profilesDirectoryURL, defaultEnabledWatchersFileURL: defaultEnabledFile
        )
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))
        let handle = try await store.openSession(result.meta.id)

        #expect(try await handle.readEnabledWatchers() == [])
    }

    @Test(".profile seed uses the profile's own populated enabled_watchers list")
    func profileSeedUsesOwnEnabledWatchers() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL, enabledWatchersYAML: "  - pre-check\n  - action-items")

        let (store, _) = makeStore(root: root, profilesDirectoryURL: profilesDirectoryURL)
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))
        let handle = try await store.openSession(result.meta.id)

        #expect(try await handle.readEnabledWatchers() == ["pre-check", "action-items"])
    }

    @Test(".profile seed falls back to default_watchers.yaml when the profile's enabled_watchers key is absent")
    func profileSeedFallsBackToDefaultWatchersWhenKeyAbsent() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL) // no enabled_watchers key at all

        let defaultEnabledFile = root.appendingPathComponent("default_watchers.yaml")
        try "enabled:\n  - pre-check\n".write(to: defaultEnabledFile, atomically: true, encoding: .utf8)

        let (store, _) = makeStore(
            root: root, profilesDirectoryURL: profilesDirectoryURL, defaultEnabledWatchersFileURL: defaultEnabledFile
        )
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))
        let handle = try await store.openSession(result.meta.id)

        #expect(try await handle.readEnabledWatchers() == ["pre-check"])
    }

    @Test(".profile seed falls all the way through to an empty enabled.yaml when both the profile and the global default are absent")
    func profileSeedFallsBackToEmptyEnabledWatchers() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL)

        let (store, _) = makeStore(root: root, profilesDirectoryURL: profilesDirectoryURL)
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))
        let handle = try await store.openSession(result.meta.id)

        #expect(try await handle.readEnabledWatchers() == [])
    }

    // MARK: - .profile seed: participants.json (§4 table row 4)

    @Test(".profile seed writes participants.json from the profile's participant_ids")
    func profileSeedWritesOwnParticipantIds() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL, participantIdsYAML: "  - spk_abc123")

        let (store, _) = makeStore(root: root, profilesDirectoryURL: profilesDirectoryURL)
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))
        let handle = try await store.openSession(result.meta.id)

        let participants = await handle.readParticipants()
        #expect(participants.participantIds == ["spk_abc123"])
        #expect(participants.removedParticipantIds.isEmpty)
    }

    @Test(".profile seed writes no participants.json at all when the profile's participant_ids key is absent (no fallback exists)")
    func profileSeedWritesNoParticipantsWhenKeyAbsent() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL)

        let (store, sessionsRoot) = makeStore(root: root, profilesDirectoryURL: profilesDirectoryURL)
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))

        let participantsURL = sessionDirectory(root: sessionsRoot, sessionId: result.meta.id).appendingPathComponent("participants.json")
        #expect(!FileManager.default.fileExists(atPath: participantsURL.path))
    }

    // MARK: - Unknown profile id: soft fallback (§4 / §8 #3)

    @Test("an unrecognized profile id falls back to global defaults, reports appliedSeed == .profileFallback(requestedId:), and does not record meta.profileId")
    func unknownProfileIdFallsBackAndReportsProfileFallback() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        // No profile with this id exists at all.

        let globalDefaultContext = root.appendingPathComponent("global-context.md")
        try "# 全体デフォルトのメモ".write(to: globalDefaultContext, atomically: true, encoding: .utf8)

        let (store, _) = makeStore(root: root, profilesDirectoryURL: profilesDirectoryURL, defaultContextFileURL: globalDefaultContext)
        let result = try await store.createDraftSession(seed: .profile(id: "nonexistent-profile"))

        #expect(result.appliedSeed == .profileFallback(requestedId: "nonexistent-profile"))
        #expect(result.meta.profileId == nil)

        let handle = try await store.openSession(result.meta.id)
        #expect(await handle.readContext() == "# 全体デフォルトのメモ")
    }

    @Test("an invalid profile id (fails MeetingProfileIdValidation) also falls back rather than throwing")
    func invalidProfileIdAlsoFallsBack() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)

        let (store, _) = makeStore(root: root, profilesDirectoryURL: profilesDirectoryURL)
        let result = try await store.createDraftSession(seed: .profile(id: "bad id!"))

        #expect(result.appliedSeed == .profileFallback(requestedId: "bad id!"))
        #expect(result.meta.profileId == nil)
    }

    // MARK: - Successful .profile resolution (§3.1 regression)

    @Test("a resolved .profile seed reports appliedSeed == .profile(id:) and records meta.profileId")
    func resolvedProfileSeedReportsProfileAndRecordsProfileId() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profilesDirectoryURL = root.appendingPathComponent("profiles", isDirectory: true)
        try writeProfile(id: "daily-scrum", in: profilesDirectoryURL)

        let (store, _) = makeStore(root: root, profilesDirectoryURL: profilesDirectoryURL)
        let result = try await store.createDraftSession(seed: .profile(id: "daily-scrum"))

        #expect(result.appliedSeed == .profile(id: "daily-scrum"))
        #expect(result.meta.profileId == "daily-scrum")
        #expect(result.meta.basedOnSession == nil, "based_on_session and profile_id are exclusive (§2.3)")
    }

    // MARK: - .basedOn / .none -> appliedSeed (regression: existing behavior must be unchanged)

    @Test(".basedOn seed reports appliedSeed == .basedOn(sessionId:) and leaves meta.profileId nil")
    func basedOnSeedReportsBasedOnAndLeavesProfileIdNil() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = makeStore(root: root)

        let source = try await store.createDraftSession(seed: .none)
        let derived = try await store.createDraftSession(seed: .basedOn(sessionId: source.meta.id))

        #expect(derived.appliedSeed == .basedOn(sessionId: source.meta.id))
        #expect(derived.meta.basedOnSession == source.meta.id)
        #expect(derived.meta.profileId == nil)
    }

    @Test(".none seed reports appliedSeed == .none and leaves both basedOnSession/profileId nil")
    func noneSeedReportsNoneAndLeavesBothProvenanceFieldsNil() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = makeStore(root: root)

        let result = try await store.createDraftSession(seed: .none)

        #expect(result.appliedSeed == .none)
        #expect(result.meta.basedOnSession == nil)
        #expect(result.meta.profileId == nil)
    }

    // MARK: - createDraftSession(basedOn:) compatibility wrapper delegates to createDraftSession(seed:)

    @Test("createDraftSession(basedOn: nil) behaves like seed: .none, returning only .meta")
    func compatWrapperWithNilBasedOnBehavesLikeNoneSeed() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = makeStore(root: root)

        let meta = try await store.createDraftSession(basedOn: nil)

        #expect(meta.basedOnSession == nil)
        #expect(meta.profileId == nil)
        #expect(meta.state == .draft)
    }

    @Test("createDraftSession(basedOn:) behaves like seed: .basedOn(sessionId:), returning only .meta")
    func compatWrapperWithBasedOnBehavesLikeBasedOnSeed() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = makeStore(root: root)

        let source = try await store.createDraftSession(basedOn: nil)
        let derived = try await store.createDraftSession(basedOn: source.id)

        #expect(derived.basedOnSession == source.id)
        #expect(derived.profileId == nil)
    }
}
