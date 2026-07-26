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
