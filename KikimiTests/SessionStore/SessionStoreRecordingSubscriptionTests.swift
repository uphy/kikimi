import Foundation
import Testing

@testable import Kikimi

/// Unit tests for the two `SessionStore` additions specified by `docs/design/06-ui-panels.md`
/// section 4/5.2/6.1: `subscribeToRecordingSessionId()` (multi-subscriber `AsyncStream<String?>`
/// broadcast) and `cancelRecording(_:)` (the Recording-start rollback API, distinct from
/// `endRecording(_:)`).
@Suite("SessionStore recording subscription & cancellation")
struct SessionStoreRecordingSubscriptionTests {
    // MARK: - Fixtures

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreRecordingSubscriptionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore() -> (store: SessionStore, root: URL) {
        let root = makeTemporaryDirectory()
        let store = SessionStore(
            sessionsRootDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            defaultContextFileURL: root.appendingPathComponent("missing-context.md"),
            defaultSummaryTemplateFileURL: root.appendingPathComponent("missing-template.md"),
            defaultEnabledWatchersFileURL: root.appendingPathComponent("missing-enabled.yaml")
        )
        return (store, root)
    }

    private func sessionDirectory(root: URL, sessionId: String) -> URL {
        root.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(sessionId, isDirectory: true)
    }

    // MARK: - subscribeToRecordingSessionId

    @Test("subscribeToRecordingSessionId yields the current value first, even when nothing is recording")
    func subscribeYieldsCurrentValueFirst() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let stream = await store.subscribeToRecordingSessionId()
        var iterator = stream.makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first == nil)
    }

    @Test("subscribeToRecordingSessionId yields the already-recording session id first for a late subscriber")
    func subscribeYieldsCurrentValueWhenAlreadyRecording() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = try await store.createDraftSession()
        _ = try await store.beginRecording(meta.id)

        let stream = await store.subscribeToRecordingSessionId()
        var iterator = stream.makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first == meta.id)
    }

    @Test("subscribeToRecordingSessionId yields a new value on every beginRecording/endRecording transition")
    func subscribeYieldsOnEveryTransition() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let stream = await store.subscribeToRecordingSessionId()
        var iterator = stream.makeAsyncIterator()

        let initial = try #require(await iterator.next())
        #expect(initial == nil)

        let meta = try await store.createDraftSession()
        _ = try await store.beginRecording(meta.id)
        let afterBegin = try #require(await iterator.next())
        #expect(afterBegin == meta.id)

        try await store.endMeeting(meta.id)
        let afterEnd = try #require(await iterator.next())
        #expect(afterEnd == nil)
    }

    @Test("subscribeToRecordingSessionId yields a new value on cancelRecording")
    func subscribeYieldsOnCancelRecording() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let stream = await store.subscribeToRecordingSessionId()
        var iterator = stream.makeAsyncIterator()
        _ = try #require(await iterator.next()) // initial nil

        let meta = try await store.createDraftSession()
        _ = try await store.beginRecording(meta.id)
        _ = try #require(await iterator.next()) // meta.id

        try await store.cancelRecordingStart(meta.id, revertingTo: .draft)
        let afterCancel = try #require(await iterator.next())
        #expect(afterCancel == nil)
    }

    @Test("subscribeToRecordingSessionId broadcasts the same sequence of values to multiple concurrent subscribers")
    func subscribeBroadcastsToMultipleSubscribers() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let streamA = await store.subscribeToRecordingSessionId()
        let streamB = await store.subscribeToRecordingSessionId()
        var iteratorA = streamA.makeAsyncIterator()
        var iteratorB = streamB.makeAsyncIterator()

        #expect(try #require(await iteratorA.next()) == nil)
        #expect(try #require(await iteratorB.next()) == nil)

        let meta = try await store.createDraftSession()
        _ = try await store.beginRecording(meta.id)

        #expect(try #require(await iteratorA.next()) == meta.id)
        #expect(try #require(await iteratorB.next()) == meta.id)

        try await store.endMeeting(meta.id)

        #expect(try #require(await iteratorA.next()) == nil)
        #expect(try #require(await iteratorB.next()) == nil)
    }

    // MARK: - cancelRecording

    @Test("cancelRecording rewinds meta.state to .draft and clears startedAt without deleting the session folder")
    func cancelRecordingRewindsMetaToDraft() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = try await store.createDraftSession()
        let handle = try await store.beginRecording(meta.id)
        #expect(await handle.meta.state == .recording)
        #expect(await handle.meta.startedAt != nil)

        try await store.cancelRecordingStart(meta.id, revertingTo: .draft)

        #expect(await handle.meta.state == .draft)
        #expect(await handle.meta.startedAt == nil)

        // The session folder itself must survive (design doc section 6.1: "セッションフォルダ自体は
        // 削除しない"), so the user can simply retry recording on the same Draft session.
        let directory = sessionDirectory(root: root, sessionId: meta.id)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meta.json").path))

        // The persisted meta.json on disk must reflect the rollback too, not just the in-memory handle.
        let onDisk = try SessionJSONCoding.makeDecoder().decode(
            SessionMeta.self,
            from: Data(contentsOf: directory.appendingPathComponent("meta.json"))
        )
        #expect(onDisk.state == .draft)
        #expect(onDisk.startedAt == nil)
    }

    @Test("cancelRecording clears recordingSessionId, freeing exclusivity for another session")
    func cancelRecordingClearsExclusivity() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try await store.createDraftSession()
        let second = try await store.createDraftSession()

        _ = try await store.beginRecording(first.id)
        #expect(await store.recordingSessionId == first.id)

        try await store.cancelRecordingStart(first.id, revertingTo: .draft)
        #expect(await store.recordingSessionId == nil)

        // The exclusivity flag being released means a different session can now begin recording.
        _ = try await store.beginRecording(second.id)
        #expect(await store.recordingSessionId == second.id)
    }

    @Test("cancelRecording throws .sessionNotInRecordingState when the target session is not the currently recording one")
    func cancelRecordingThrowsWhenNotRecording() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draftOnly = try await store.createDraftSession()
        await #expect(throws: SessionStoreError.sessionNotInRecordingState(draftOnly.id)) {
            try await store.cancelRecordingStart(draftOnly.id, revertingTo: .draft)
        }

        let first = try await store.createDraftSession()
        let second = try await store.createDraftSession()
        _ = try await store.beginRecording(first.id)

        // `second` is Draft, and `first` (not `second`) is the currently recording session, so
        // cancelling `second` must fail rather than silently cancelling `first`.
        await #expect(throws: SessionStoreError.sessionNotInRecordingState(second.id)) {
            try await store.cancelRecordingStart(second.id, revertingTo: .draft)
        }
        #expect(await store.recordingSessionId == first.id)
    }

    @Test("cancelRecording leaves the session in .draft state, allowing beginRecording to be retried")
    func cancelRecordingAllowsRetry() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = try await store.createDraftSession()
        _ = try await store.beginRecording(meta.id)
        try await store.cancelRecordingStart(meta.id, revertingTo: .draft)

        let handle = try await store.beginRecording(meta.id)
        #expect(await handle.meta.state == .recording)
        #expect(await store.recordingSessionId == meta.id)
    }
}
