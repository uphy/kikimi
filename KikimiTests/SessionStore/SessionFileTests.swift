import Foundation
import Testing

@testable import Kikimi

// MARK: - SessionFile

@Suite("SessionFile")
struct SessionFileTests {
    @Test("resolves every fixed (non-watcher) case to its documented relative path")
    func fixedCasesResolveToDocumentedPaths() throws {
        #expect(try SessionFile.meta.relativePath() == "meta.json")
        #expect(try SessionFile.context.relativePath() == "context.md")
        #expect(try SessionFile.summaryTemplate.relativePath() == "summary_template.md")
        #expect(try SessionFile.transcriptJSONL.relativePath() == "transcript.jsonl")
        #expect(try SessionFile.refinedJSONL.relativePath() == "refined.jsonl")
        #expect(try SessionFile.speakerAssignments.relativePath() == "speaker_assignments.json")
        #expect(try SessionFile.participants.relativePath() == "participants.json")
        #expect(try SessionFile.summaryState.relativePath() == "summary.state.json")
        #expect(try SessionFile.summaryMarkdown.relativePath() == "summary.md")
        #expect(try SessionFile.watchersEnabled.relativePath() == "watchers/enabled.yaml")
    }

    @Test("resolves watcherDefinition(id:) to watchers/<id>.md")
    func watcherDefinitionResolvesUnderWatchersSubdirectory() throws {
        #expect(try SessionFile.watcherDefinition(id: "pre-check").relativePath() == "watchers/pre-check.md")
    }

    @Test("resolves watcherState(id:) to watchers/<id>.state.json")
    func watcherStateResolvesUnderWatchersSubdirectory() throws {
        #expect(
            try SessionFile.watcherState(id: "pre-check").relativePath() == "watchers/pre-check.state.json"
        )
    }

    @Test("resolves watcherRunRecord(id:) to watchers/<id>.run.json")
    func watcherRunRecordResolvesUnderWatchersSubdirectory() throws {
        #expect(
            try SessionFile.watcherRunRecord(id: "pre-check").relativePath() == "watchers/pre-check.run.json"
        )
    }

    @Test(
        "accepts watcher ids made only of ASCII letters, digits, and hyphens",
        arguments: ["pre-check", "action-items", "risk1", "ABC", "a", "123", "a-b-c-123"]
    )
    func acceptsValidWatcherIds(id: String) throws {
        #expect(try SessionFile.watcherDefinition(id: id).relativePath() == "watchers/\(id).md")
        #expect(try SessionFile.watcherState(id: id).relativePath() == "watchers/\(id).state.json")
        #expect(try SessionFile.watcherRunRecord(id: id).relativePath() == "watchers/\(id).run.json")
    }

    @Test(
        "rejects watcher ids containing anything other than ASCII letters/digits/hyphens",
        arguments: [
            "",
            "pre check",
            "pre_check",
            "pre.check",
            "../../etc/passwd",
            "watchers/evil",
            "日本語",
            "a/b",
            "a\\b",
            "café"
        ]
    )
    func rejectsInvalidWatcherIds(id: String) {
        #expect(throws: SessionFileError.invalidWatcherId(id)) {
            try SessionFile.watcherDefinition(id: id).relativePath()
        }
        #expect(throws: SessionFileError.invalidWatcherId(id)) {
            try SessionFile.watcherState(id: id).relativePath()
        }
        #expect(throws: SessionFileError.invalidWatcherId(id)) {
            try SessionFile.watcherRunRecord(id: id).relativePath()
        }
    }

    @Test("invalidWatcherId errorDescription is non-empty and mentions the offending id")
    func invalidWatcherIdErrorDescription() throws {
        let error = SessionFileError.invalidWatcherId("../etc")
        let description = try #require(error.errorDescription)
        #expect(!description.isEmpty)
        #expect(description.contains("../etc"))
    }

    @Test("equatable distinguishes cases and associated watcher ids")
    func equatable() {
        #expect(SessionFile.meta == .meta)
        #expect(SessionFile.meta != .context)
        #expect(SessionFile.watcherDefinition(id: "a") == .watcherDefinition(id: "a"))
        #expect(SessionFile.watcherDefinition(id: "a") != .watcherDefinition(id: "b"))
        #expect(SessionFile.watcherDefinition(id: "a") != .watcherState(id: "a"))
    }
}

// MARK: - GenericAccessibleFile

@Suite("GenericAccessibleFile")
struct GenericAccessibleFileTests {
    @Test("asSessionFile maps each case to the matching SessionFile case")
    func asSessionFileMapsEachCase() {
        #expect(GenericAccessibleFile.summaryState.asSessionFile == .summaryState)
        #expect(GenericAccessibleFile.summaryMarkdown.asSessionFile == .summaryMarkdown)
        #expect(GenericAccessibleFile.watcherDefinition(id: "pre-check").asSessionFile == .watcherDefinition(id: "pre-check"))
        #expect(GenericAccessibleFile.watcherState(id: "pre-check").asSessionFile == .watcherState(id: "pre-check"))
    }

    @Test("relativePath() matches asSessionFile.relativePath() for every case")
    func relativePathMatchesBridgedSessionFile() throws {
        let cases: [GenericAccessibleFile] = [
            .summaryState,
            .summaryMarkdown,
            .watcherDefinition(id: "pre-check"),
            .watcherState(id: "pre-check")
        ]

        for file in cases {
            #expect(try file.relativePath() == (try file.asSessionFile.relativePath()))
        }
    }

    @Test("resolves the fixed cases to their documented relative paths")
    func fixedCasesResolveToDocumentedPaths() throws {
        #expect(try GenericAccessibleFile.summaryState.relativePath() == "summary.state.json")
        #expect(try GenericAccessibleFile.summaryMarkdown.relativePath() == "summary.md")
    }

    @Test("propagates SessionFileError.invalidWatcherId for invalid watcher ids")
    func propagatesInvalidWatcherIdError() {
        #expect(throws: SessionFileError.invalidWatcherId("bad id")) {
            try GenericAccessibleFile.watcherDefinition(id: "bad id").relativePath()
        }
        #expect(throws: SessionFileError.invalidWatcherId("bad id")) {
            try GenericAccessibleFile.watcherState(id: "bad id").relativePath()
        }
    }

    @Test("cannot express the reserved-API-only cases (meta/context/summaryTemplate/transcriptJSONL/refinedJSONL/watchersEnabled)")
    func reservedCasesAreNotExpressible() {
        // This test documents the compile-time guarantee from design doc section 5.2.1: none of
        // `.meta`, `.context`, `.summaryTemplate`, `.transcriptJSONL`, `.refinedJSONL`, or
        // `.watchersEnabled` exist as `GenericAccessibleFile` cases, so code such as
        // `GenericAccessibleFile.transcriptJSONL` simply does not compile. There is nothing to
        // assert at runtime; the guarantee is enforced by the type system itself.
    }
}
