import Foundation
import Testing

@testable import Kikimi

// MARK: - SessionState

@Suite("SessionState")
struct SessionStateTests {
    @Test("raw values match the on-disk meta.json identifiers for draft/recording/ended")
    func rawValues() {
        #expect(SessionState.draft.rawValue == "draft")
        #expect(SessionState.recording.rawValue == "recording")
        #expect(SessionState.ended.rawValue == "ended")
    }

    @Test("round-trips through Codable using its raw string value")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for state in [SessionState.draft, .recording, .ended] {
            let data = try encoder.encode(state)
            #expect(String(data: data, encoding: .utf8) == "\"\(state.rawValue)\"")
            let decoded = try decoder.decode(SessionState.self, from: data)
            #expect(decoded == state)
        }
    }

    @Test("decoding an unknown state string fails rather than silently defaulting")
    func decodingUnknownValueFails() {
        let decoder = JSONDecoder()
        let data = Data("\"archived\"".utf8)
        #expect(throws: (any Error).self) {
            try decoder.decode(SessionState.self, from: data)
        }
    }
}

// MARK: - SessionStoreError

@Suite("SessionStoreError")
struct SessionStoreErrorTests {
    @Test("errorDescription is non-empty and human-readable for every one of the 8 documented cases")
    func allCasesHaveNonEmptyDescriptions() throws {
        let cases: [SessionStoreError] = [
            .sessionNotFound("2026-07-01T14-30-00_a1b2c3d4"),
            .anotherSessionRecording(activeSessionId: "2026-07-01T10-00-00_11112222"),
            .sessionNotInDraftState("2026-07-01T14-30-00_a1b2c3d4"),
            .sessionNotInRecordingState("2026-07-01T14-30-00_a1b2c3d4"),
            .directoryCreationFailed("disk full"),
            .directoryDeletionFailed("file in use"),
            .cannotDeleteActiveRecording("2026-07-01T14-30-00_a1b2c3d4"),
            .invalidSessionId("../../etc")
        ]

        for error in cases {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
        }
    }

    @Test("errorDescription interpolates the associated session id / message verbatim")
    func descriptionInterpolatesAssociatedValues() throws {
        let notFound = SessionStoreError.sessionNotFound("session-a")
        #expect(try #require(notFound.errorDescription).contains("session-a"))

        let anotherRecording = SessionStoreError.anotherSessionRecording(activeSessionId: "session-b")
        #expect(try #require(anotherRecording.errorDescription).contains("session-b"))

        let notDraft = SessionStoreError.sessionNotInDraftState("session-c")
        #expect(try #require(notDraft.errorDescription).contains("session-c"))

        let notRecording = SessionStoreError.sessionNotInRecordingState("session-d")
        #expect(try #require(notRecording.errorDescription).contains("session-d"))

        let dirCreate = SessionStoreError.directoryCreationFailed("permission denied")
        #expect(try #require(dirCreate.errorDescription).contains("permission denied"))

        let dirDelete = SessionStoreError.directoryDeletionFailed("ENOTEMPTY")
        #expect(try #require(dirDelete.errorDescription).contains("ENOTEMPTY"))

        let cannotDelete = SessionStoreError.cannotDeleteActiveRecording("session-e")
        #expect(try #require(cannotDelete.errorDescription).contains("session-e"))

        let invalidId = SessionStoreError.invalidSessionId("../../etc")
        #expect(try #require(invalidId.errorDescription).contains("../../etc"))
    }

    @Test("equatable distinguishes cases and associated values, including same case with different payloads")
    func equatable() {
        #expect(SessionStoreError.sessionNotFound("a") == .sessionNotFound("a"))
        #expect(SessionStoreError.sessionNotFound("a") != .sessionNotFound("b"))
        #expect(SessionStoreError.sessionNotFound("a") != .sessionNotInDraftState("a"))

        #expect(
            SessionStoreError.anotherSessionRecording(activeSessionId: "x")
                == .anotherSessionRecording(activeSessionId: "x")
        )
        #expect(
            SessionStoreError.anotherSessionRecording(activeSessionId: "x")
                != .anotherSessionRecording(activeSessionId: "y")
        )

        #expect(SessionStoreError.directoryCreationFailed("x") == .directoryCreationFailed("x"))
        #expect(SessionStoreError.directoryCreationFailed("x") != .directoryDeletionFailed("x"))
    }
}

// MARK: - SessionIdValidation

@Suite("SessionIdValidation")
struct SessionIdValidationTests {
    @Test("accepts session ids in SessionStore's own generated shape and other plain single-component strings")
    func acceptsValidIds() throws {
        for id in ["2026-07-01T14-30-00_a1b2c3d4", "corrupt-session", "a", "does-not-exist"] {
            try SessionIdValidation.validate(id)
        }
    }

    @Test("rejects ids that would escape sessionsRootDirectory when resolved via appendingPathComponent")
    func rejectsPathTraversal() {
        for id in ["", ".", "..", "../evil", "../../etc/passwd", "a/b", "/etc/passwd", "sub/../../escape"] {
            #expect(throws: SessionStoreError.invalidSessionId(id)) {
                try SessionIdValidation.validate(id)
            }
        }
    }
}

// MARK: - DraftSeed / AppliedDraftSeed / DraftCreationResult

/// Layer 1 (unit) coverage for the pure `DraftSeed`/`AppliedDraftSeed`/`DraftCreationResult` types
/// themselves (`docs/design/41-meeting-profiles.md` §3.1), direct and isolated -- as opposed to
/// `SessionStoreDraftSeedTests.swift`, which drives the full `createDraftSession(seed:)` actor call
/// end to end (real directories, real `MeetingProfileStore` reads) and only observes these types'
/// values indirectly through its result. `AppliedDraftSeed.basedOnSessionForMeta`/`.profileIdForMeta`
/// in particular are exercised here against every case directly, rather than only via the two
/// `SessionMeta` fields those helpers happen to feed downstream.
@Suite("DraftSeed / AppliedDraftSeed / DraftCreationResult")
struct DraftSeedTests {
    // MARK: - DraftSeed Equatable

    @Test("DraftSeed distinguishes cases and associated values")
    func draftSeedEquatable() {
        #expect(DraftSeed.none == .none)
        #expect(DraftSeed.basedOn(sessionId: "a") == .basedOn(sessionId: "a"))
        #expect(DraftSeed.basedOn(sessionId: "a") != .basedOn(sessionId: "b"))
        #expect(DraftSeed.profile(id: "p") == .profile(id: "p"))
        #expect(DraftSeed.profile(id: "p") != .profile(id: "q"))
        #expect(DraftSeed.none != .basedOn(sessionId: "a"))
        #expect(DraftSeed.basedOn(sessionId: "a") != .profile(id: "a"))
    }

    // MARK: - AppliedDraftSeed Equatable

    @Test("AppliedDraftSeed distinguishes cases and associated values, including profileFallback's requestedId")
    func appliedDraftSeedEquatable() {
        #expect(AppliedDraftSeed.none == .none)
        #expect(AppliedDraftSeed.basedOn(sessionId: "a") == .basedOn(sessionId: "a"))
        #expect(AppliedDraftSeed.basedOn(sessionId: "a") != .basedOn(sessionId: "b"))
        #expect(AppliedDraftSeed.profile(id: "p") == .profile(id: "p"))
        #expect(AppliedDraftSeed.profile(id: "p") != .profile(id: "q"))
        #expect(AppliedDraftSeed.profileFallback(requestedId: "p") == .profileFallback(requestedId: "p"))
        #expect(AppliedDraftSeed.profileFallback(requestedId: "p") != .profileFallback(requestedId: "q"))
        // .profile and .profileFallback with the same id string are still distinct cases (§4: a
        // resolved profile records meta.profileId; a fallback deliberately does not).
        #expect(AppliedDraftSeed.profile(id: "p") != .profileFallback(requestedId: "p"))
    }

    // MARK: - AppliedDraftSeed -> SessionMeta field mapping (§2.3, §4)

    @Test("basedOnSessionForMeta is non-nil only for .basedOn, and carries its sessionId verbatim")
    func basedOnSessionForMeta() {
        #expect(AppliedDraftSeed.none.basedOnSessionForMeta == nil)
        #expect(AppliedDraftSeed.basedOn(sessionId: "2026-07-01T14-30-00_a1b2c3d4").basedOnSessionForMeta == "2026-07-01T14-30-00_a1b2c3d4")
        #expect(AppliedDraftSeed.profile(id: "daily-scrum").basedOnSessionForMeta == nil)
        #expect(AppliedDraftSeed.profileFallback(requestedId: "daily-scrum").basedOnSessionForMeta == nil)
    }

    @Test("profileIdForMeta is non-nil only for a successfully resolved .profile, never for .profileFallback (§4: 記録しない)")
    func profileIdForMeta() {
        #expect(AppliedDraftSeed.none.profileIdForMeta == nil)
        #expect(AppliedDraftSeed.basedOn(sessionId: "a").profileIdForMeta == nil)
        #expect(AppliedDraftSeed.profile(id: "daily-scrum").profileIdForMeta == "daily-scrum")
        #expect(AppliedDraftSeed.profileFallback(requestedId: "daily-scrum").profileIdForMeta == nil)
    }

    @Test("basedOnSessionForMeta and profileIdForMeta are mutually exclusive across every case (§2.3: exclusive fields)")
    func basedOnSessionAndProfileIdAreMutuallyExclusive() {
        let cases: [AppliedDraftSeed] = [
            .none,
            .basedOn(sessionId: "a"),
            .profile(id: "p"),
            .profileFallback(requestedId: "p")
        ]
        for appliedSeed in cases {
            #expect(appliedSeed.basedOnSessionForMeta == nil || appliedSeed.profileIdForMeta == nil)
        }
    }

    // MARK: - DraftCreationResult Equatable

    @Test("DraftCreationResult is equal iff both meta and appliedSeed are equal")
    func draftCreationResultEquatable() {
        let meta = SessionMeta(
            id: "2026-07-01T14-30-00_a1b2c3d4",
            title: "",
            titleAutoGenerated: true,
            titleAutoNamedOnce: false,
            titleProposal: nil,
            state: .draft,
            createdAt: Date(timeIntervalSince1970: 1_751_000_000),
            startedAt: nil,
            endedAt: nil,
            durationMs: 0,
            basedOnSession: nil,
            profileId: "daily-scrum",
            segmentCount: 0,
            refinedCount: 0,
            appVersion: "0.1.0"
        )
        var differentMeta = meta
        differentMeta.title = "違うタイトル"

        #expect(DraftCreationResult(meta: meta, appliedSeed: .profile(id: "daily-scrum")) == DraftCreationResult(meta: meta, appliedSeed: .profile(id: "daily-scrum")))
        #expect(DraftCreationResult(meta: meta, appliedSeed: .profile(id: "daily-scrum")) != DraftCreationResult(meta: differentMeta, appliedSeed: .profile(id: "daily-scrum")))
        #expect(DraftCreationResult(meta: meta, appliedSeed: .profile(id: "daily-scrum")) != DraftCreationResult(meta: meta, appliedSeed: .profileFallback(requestedId: "daily-scrum")))
    }
}

// MARK: - PrepCopyScope

@Suite("PrepCopyScope")
struct PrepCopyScopeTests {
    @Test("all three documented scopes (contextOnly/templateOnly/both) are distinguishable via switch")
    func allCasesAreDistinguishable() {
        func label(for scope: PrepCopyScope) -> String {
            switch scope {
            case .contextOnly: return "contextOnly"
            case .templateOnly: return "templateOnly"
            case .both: return "both"
            }
        }

        #expect(label(for: .contextOnly) == "contextOnly")
        #expect(label(for: .templateOnly) == "templateOnly")
        #expect(label(for: .both) == "both")
    }
}

// MARK: - FileManager.expandingTildePath

/// Layer 1 coverage for the tilde-expansion helper `docs/design/05-watcher-runner.md` §3.2 introduces
/// (`WatchersConfig`'s `presets_dir`/`default_enabled_file` and `SessionStore.shared`'s
/// `defaultEnabledWatchersFileURL` both resolve through this).
@Suite("FileManager.expandingTildePath")
struct FileManagerExpandingTildePathTests {
    @Test("a bare \"~\" expands to realHomeDirectory")
    func expandsBareTilde() {
        #expect(FileManager.expandingTildePath("~") == FileManager.realHomeDirectory)
    }

    @Test("a \"~/...\" path expands relative to realHomeDirectory")
    func expandsTildeSlashPath() {
        let expanded = FileManager.expandingTildePath("~/.config/kikimi/watchers/")
        #expect(expanded == FileManager.realHomeDirectory.appendingPathComponent(".config/kikimi/watchers/"))
    }

    @Test("an absolute path (no leading tilde) is returned unchanged")
    func absolutePathIsUnchanged() {
        #expect(FileManager.expandingTildePath("/etc/kikimi/config.yaml") == URL(fileURLWithPath: "/etc/kikimi/config.yaml"))
    }
}
