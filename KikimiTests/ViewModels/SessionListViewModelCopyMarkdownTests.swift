import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `SessionListViewModel.copyMarkdown(sessionId:)`
/// (`Kikimi/ViewModels/SessionListViewModel.swift:300`, `docs/design/37-transcript-markdown-copy.md`
/// §7's "`SessionListViewModel.copyMarkdown` テスト").
///
/// **Scope note**: unlike `markdownSource`/`pasteboard`, `copyMarkdown(sessionId:)` reads the session
/// itself through the hardcoded `SessionStore.shared` singleton -- there is no constructor seam to
/// substitute a temporary-directory-backed store the way `SessionStoreTests.swift` does for every
/// other `SessionStore` test. The **not-found** cases below exercise that read-only path (an id that
/// `SessionStore.shared.readOnlySessionHandle(_:)` can resolve to `nil` without creating or touching
/// any file -- either because it fails `SessionIdValidation` or because no such session directory
/// exists on disk), which is exactly the design doc §6 failure mode "一覧経路でセッションフォルダが
/// 読み取り専用ハンドルからも開けない". The remaining §7 assertions (successful clipboard content, the
/// injected `PasteboardWriting` fake returning `false` after a *successful* load, and the Draft "no
/// `transcript.jsonl`/`refined.jsonl` side effect" regression) require a real on-disk session, so each
/// of those tests creates its own throwaway Draft session via `SessionStore.shared.createDraftSession()`
/// (a fresh, `EntryIdNaming`-minted id that can never collide with a real session) and removes the
/// whole directory in a `defer` -- the same "no substitute exists, so touch the real singleton and
/// clean up after" acceptance already established for `NSPasteboard.general` in
/// `KikimiTests/Markdown/PasteboardWritingTests.swift`. `.serialized` keeps every test in this suite
/// from racing another test's use of the `SessionStore.shared.handles` cache.
@Suite("SessionListViewModel.copyMarkdown(sessionId:)", .serialized)
@MainActor
struct SessionListViewModelCopyMarkdownTests {
    // MARK: - Fakes

    /// Records every `writeString(_:)` call so tests can assert the pasteboard was never touched on
    /// the not-found path, and (for the real-session tests below) inspect the last string written.
    /// `@unchecked Sendable` + `NSLock`, mirroring `MeetingWorkspaceViewModel+WatchersTests.swift`'s
    /// `SimpleWatcherIdSequence` fake -- required because `PasteboardWriting: Sendable`
    /// (`Kikimi/Markdown/PasteboardWriting.swift`).
    private final class RecordingPasteboardFake: PasteboardWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var writtenStrings: [String] = []
        private let result: Bool

        init(result: Bool = true) {
            self.result = result
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return writtenStrings.count
        }

        /// The most recent `writeString(_:)` argument, for the success-path content assertion below.
        /// `nil` if `writeString(_:)` was never called.
        var lastWrittenString: String? {
            lock.lock()
            defer { lock.unlock() }
            return writtenStrings.last
        }

        func writeString(_ string: String) -> Bool {
            lock.lock()
            writtenStrings.append(string)
            lock.unlock()
            return result
        }
    }

    private func makeMarkdownSource() -> (source: TranscriptMarkdownSource, voiceprintFileURL: URL) {
        let voiceprintFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionListViewModelCopyMarkdownTests-voiceprints-\(UUID().uuidString).json")
        let source = TranscriptMarkdownSource(diarization: .default, voiceprintStore: VoiceprintStore(fileURL: voiceprintFileURL))
        return (source, voiceprintFileURL)
    }

    private func makeViewModel(pasteboard: PasteboardWriting) -> SessionListViewModel {
        let (source, _) = makeMarkdownSource()
        return SessionListViewModel(markdownSource: source, pasteboard: pasteboard)
    }

    // MARK: - Not-found path (design §6: "セッションフォルダが読み取り専用ハンドルからも開けない")

    @Test("a well-formed but nonexistent session id sets toast to .markdownCopyFailed and never writes to the pasteboard")
    func nonexistentSessionIdSetsMarkdownCopyFailedToast() async {
        let pasteboard = RecordingPasteboardFake()
        let viewModel = makeViewModel(pasteboard: pasteboard)
        // Well-formed (matches the `{ISO8601}_{shortUUID}` shape `SessionIdValidation.validate(_:)`
        // accepts -- it only rejects empty/"."/".."/ "/"-containing ids, not this specific shape, but
        // using the real shape keeps the fixture representative) yet guaranteed to never exist on disk.
        let sessionId = "1970-01-01T00-00-00_00000000-nonexistent-fixture"

        await viewModel.copyMarkdown(sessionId: sessionId)

        #expect(viewModel.toast == .markdownCopyFailed)
        #expect(pasteboard.callCount == 0)
    }

    @Test("a session id that fails SessionIdValidation (contains \"/\") sets toast to .markdownCopyFailed and never writes to the pasteboard")
    func invalidSessionIdSetsMarkdownCopyFailedToast() async {
        let pasteboard = RecordingPasteboardFake()
        let viewModel = makeViewModel(pasteboard: pasteboard)
        let sessionId = "../escape-attempt"

        await viewModel.copyMarkdown(sessionId: sessionId)

        #expect(viewModel.toast == .markdownCopyFailed)
        #expect(pasteboard.callCount == 0)
    }

    @Test("the empty string session id (fails SessionIdValidation) sets toast to .markdownCopyFailed")
    func emptySessionIdSetsMarkdownCopyFailedToast() async {
        let pasteboard = RecordingPasteboardFake()
        let viewModel = makeViewModel(pasteboard: pasteboard)

        await viewModel.copyMarkdown(sessionId: "")

        #expect(viewModel.toast == .markdownCopyFailed)
        #expect(pasteboard.callCount == 0)
    }

    @Test("toast starts nil before copyMarkdown(sessionId:) is ever called")
    func toastStartsNil() {
        let pasteboard = RecordingPasteboardFake()
        let viewModel = makeViewModel(pasteboard: pasteboard)

        #expect(viewModel.toast == nil)
    }

    // MARK: - Real-session paths (§7's "成功時のクリップボード内容"/フェイクが false を返した場合/
    // Draft セッションの副作用回避)
    //
    // Each test below creates its own throwaway Draft session and removes the whole directory in a
    // `defer`, per this file's top doc comment.

    private func sessionDirectory(_ sessionId: String) -> URL {
        SessionStore.defaultSessionsRootDirectory.appendingPathComponent(sessionId, isDirectory: true)
    }

    private func removeSessionDirectory(_ sessionId: String) {
        try? FileManager.default.removeItem(at: sessionDirectory(sessionId))
    }

    @Test("copyMarkdown writes the full rendered Markdown to the pasteboard and shows .markdownCopied")
    func copyMarkdownSuccessWritesRenderedMarkdown() async throws {
        let created = try await SessionStore.shared.createDraftSession()
        defer { removeSessionDirectory(created.id) }
        let handle = try await SessionStore.shared.openSession(created.id)
        try await handle.updateMeta { meta in
            meta.title = "定例MTG"
            meta.state = .ended
        }
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 1_000, text: "raw", confidence: 0.9)
        try await handle.appendRefinedSegment(
            RefinedSegment(
                id: segment.id, startMs: segment.startMs, endMs: segment.endMs, speaker: .mic,
                rawText: segment.text, refinedText: "整形済みテキスト", error: nil,
                refinedAt: Date(), model: "claude-haiku-4-5-20251001", batchId: "batch_00001"
            )
        )

        let (markdownSource, voiceprintFileURL) = makeMarkdownSource()
        defer { try? FileManager.default.removeItem(at: voiceprintFileURL) }
        let pasteboard = RecordingPasteboardFake()
        let viewModel = SessionListViewModel(markdownSource: markdownSource, pasteboard: pasteboard)

        await viewModel.copyMarkdown(sessionId: created.id)

        #expect(viewModel.toast == .markdownCopied)
        #expect(pasteboard.callCount == 1)
        let written = try #require(pasteboard.lastWrittenString)
        #expect(written.contains("# 定例MTG"))
        #expect(written.contains("整形済みテキスト"))
        #expect(written.contains("session_id: \(created.id)"), "scope == .full must include frontmatter")
    }

    @Test("copyMarkdown shows .markdownCopyFailed when the pasteboard write itself returns false, even though loading succeeded")
    func copyMarkdownShowsFailedToastWhenPasteboardWriteFails() async throws {
        let created = try await SessionStore.shared.createDraftSession()
        defer { removeSessionDirectory(created.id) }

        let (markdownSource, voiceprintFileURL) = makeMarkdownSource()
        defer { try? FileManager.default.removeItem(at: voiceprintFileURL) }
        let pasteboard = RecordingPasteboardFake(result: false)
        let viewModel = SessionListViewModel(markdownSource: markdownSource, pasteboard: pasteboard)

        await viewModel.copyMarkdown(sessionId: created.id)

        #expect(viewModel.toast == .markdownCopyFailed)
        #expect(pasteboard.callCount == 1, "the write is still attempted; only its reported result determines the toast")
    }

    @Test("copyMarkdown never creates transcript.jsonl/refined.jsonl for a Draft session that was never opened this run")
    func copyMarkdownDoesNotCreateLogFilesForUnopenedDraftSession() async throws {
        let created = try await SessionStore.shared.createDraftSession()
        defer { removeSessionDirectory(created.id) }
        let directory = sessionDirectory(created.id)
        let transcriptURL = directory.appendingPathComponent("transcript.jsonl")
        let refinedURL = directory.appendingPathComponent("refined.jsonl")

        // `createDraftSession()` itself already calls `ensureTranscriptAndRefinedLogFilesExist()` once
        // (`SessionStore.swift`), so both files exist immediately after creation regardless of what
        // this test does next -- that call is not the regression this test guards against. What must
        // never happen is a *second*, copy-triggered creation for a session this `SessionStore`
        // instance has not `openSession(_:)`-ed in the current process: deleting both files here
        // (simulating a Draft folder whose log files are otherwise absent, and giving
        // `SessionStore.shared.handles` no cached entry for `created.id` to serve from -- this test
        // never calls `openSession(created.id)`) makes that distinction observable.
        try FileManager.default.removeItem(at: transcriptURL)
        try FileManager.default.removeItem(at: refinedURL)
        #expect(!FileManager.default.fileExists(atPath: transcriptURL.path))
        #expect(!FileManager.default.fileExists(atPath: refinedURL.path))

        let (markdownSource, voiceprintFileURL) = makeMarkdownSource()
        defer { try? FileManager.default.removeItem(at: voiceprintFileURL) }
        let pasteboard = RecordingPasteboardFake()
        // Deliberately never calls `SessionStore.shared.openSession(created.id)` -- this session must
        // hit `readOnlySessionHandle(_:)`'s from-disk branch (design §3.2(b)), not the cached-handle
        // branch, so the regression this test guards (`openSession(_:)`'s
        // `ensureTranscriptAndRefinedLogFilesExist()` side effect) is actually exercised.
        let viewModel = SessionListViewModel(markdownSource: markdownSource, pasteboard: pasteboard)

        await viewModel.copyMarkdown(sessionId: created.id)

        #expect(viewModel.toast == .markdownCopied)
        #expect(!FileManager.default.fileExists(atPath: transcriptURL.path))
        #expect(!FileManager.default.fileExists(atPath: refinedURL.path))
    }
}
