import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `SessionStore+LLMUsage.swift`'s `readAllLLMUsageRecords()`
/// (`docs/design/16-llm-usage-stats.md` section 5's Session List footer all-time total). Mirrors
/// `SessionStoreTests`'s pattern of rooting `SessionStore` at a fresh temporary directory via the DI
/// initializer, so nothing here ever touches a real `~/.local/state/kikimi`.
@Suite("SessionStore+LLMUsage")
struct SessionStoreLLMUsageTests {
    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreLLMUsageTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a `SessionStore` rooted at a fresh temporary directory, matching
    /// `SessionStoreTests.makeStore(...)`'s defaults (nonexistent context/template/enabled-watchers
    /// files, since this suite only cares about `llm_usage.jsonl`).
    private func makeStore(root: URL) -> SessionStore {
        SessionStore(
            sessionsRootDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            defaultContextFileURL: root.appendingPathComponent("missing-context.md"),
            defaultSummaryTemplateFileURL: root.appendingPathComponent("missing-template.md"),
            defaultEnabledWatchersFileURL: root.appendingPathComponent("missing-enabled.yaml")
        )
    }

    private func makeRecord(purpose: String, model: String = "claude-haiku-4-5-20251001") -> LLMUsageRecord {
        LLMUsageRecord(
            timestamp: Date(timeIntervalSince1970: 1_751_000_100),
            purpose: purpose,
            model: model,
            inputTokens: 100,
            outputTokens: 50,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            reportedCostUSD: 0.001
        )
    }

    @Test("readAllLLMUsageRecords returns an empty array when the sessions root does not exist yet")
    func returnsEmptyWhenRootMissing() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        let records = await store.readAllLLMUsageRecords()
        #expect(records.isEmpty)
    }

    @Test("readAllLLMUsageRecords aggregates llm_usage.jsonl across multiple sessions")
    func aggregatesAcrossSessions() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        let first = try await store.createDraftSession()
        let firstHandle = try await store.openSession(first.id)
        let firstRecord = makeRecord(purpose: "refinement")
        try await firstHandle.appendLLMUsageRecord(firstRecord)

        let second = try await store.createDraftSession()
        let secondHandle = try await store.openSession(second.id)
        let secondRecordA = makeRecord(purpose: "summary_patch")
        let secondRecordB = makeRecord(purpose: "final_title")
        try await secondHandle.appendLLMUsageRecord(secondRecordA)
        try await secondHandle.appendLLMUsageRecord(secondRecordB)

        // A third session that never called an LLM (no llm_usage.jsonl at all) must not break
        // aggregation, and must not contribute any records.
        _ = try await store.createDraftSession()

        let records = await store.readAllLLMUsageRecords()
        #expect(records.count == 3)
        #expect(records.contains(firstRecord))
        #expect(records.contains(secondRecordA))
        #expect(records.contains(secondRecordB))
    }

    @Test("readAllLLMUsageRecords treats a session with no llm_usage.jsonl as contributing zero records")
    func sessionWithoutUsageFileContributesNothing() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        _ = try await store.createDraftSession()

        let records = await store.readAllLLMUsageRecords()
        #expect(records.isEmpty)
    }

    @Test("readAllLLMUsageRecords skips a corrupt line in one session's llm_usage.jsonl but still returns everything else")
    func skipsCorruptLineInOneSession() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        let session = try await store.createDraftSession()
        let handle = try await store.openSession(session.id)
        let good = makeRecord(purpose: "refinement")
        try await handle.appendLLMUsageRecord(good)

        let sessionDirectory = root.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(session.id, isDirectory: true)
        let fileURL = sessionDirectory.appendingPathComponent("llm_usage.jsonl")
        let corruptingHandle = try FileHandle(forWritingTo: fileURL)
        _ = try corruptingHandle.seekToEnd()
        try corruptingHandle.write(contentsOf: Data("not valid json\n".utf8))
        try corruptingHandle.close()

        let another = makeRecord(purpose: "final_title")
        try await handle.appendLLMUsageRecord(another)

        let records = await store.readAllLLMUsageRecords()
        #expect(records == [good, another])
    }

    @Test("readAllLLMUsageRecords skips a session whose directory disappears without breaking aggregation")
    func skipsUnreadableSessionDirectory() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        let good = try await store.createDraftSession()
        let goodHandle = try await store.openSession(good.id)
        let goodRecord = makeRecord(purpose: "refinement")
        try await goodHandle.appendLLMUsageRecord(goodRecord)

        // A directory entry under `sessions/` with no meta.json / llm_usage.jsonl at all (not a
        // session `SessionStore` ever created) must not break the scan.
        let strayDirectory = root.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("not-a-session", isDirectory: true)
        try FileManager.default.createDirectory(at: strayDirectory, withIntermediateDirectories: true)

        let records = await store.readAllLLMUsageRecords()
        #expect(records == [goodRecord])
    }
}
