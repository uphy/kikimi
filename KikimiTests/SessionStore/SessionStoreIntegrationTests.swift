import Foundation
import Testing

@testable import Kikimi

/// End-to-end exercise of `SessionStore`/`SessionHandle` against real files on disk, driven the way
/// `06-ui-panels.md`'s not-yet-wired UI would drive them across an entire meeting's lifecycle. This
/// is the "kikimi-verify via UI" substitute agreed for this module (see
/// `AudioCaptureIntegrationTests.swift` for the same pattern applied to `AudioCapture`): `KikimiApp.swift`
/// does not yet call into `SessionStore` at all (no Session Window / Session List exists), so there
/// is nothing to click through. Instead this file walks one `SessionStore` instance through
/// Draft -> Recording (real transcript/refined append + generic-storage writes) -> Ended, then
/// constructs a **second, independent `SessionStore`** rooted at the same on-disk directory to stand
/// in for an app relaunch and verifies every file this module owns (`docs/design/07-session-store.md`
/// section 4 "セッションフォルダ構造") survives that relaunch with content that matches what was written,
/// plus a second scenario covering the crash-recovery path (section 10) the same way.
///
/// Unlike the granular per-method unit tests in the sibling `SessionStoreTests.swift` (which
/// deliberately point most fixtures at *missing* default-file paths to exercise section 8's fallback
/// behavior), this file seeds real default context/template/enabled-watchers files with real content,
/// so `createDraftSession()`'s happy-path copy-on-create flow (section 8's table, first row) is
/// exercised against actual file reads too, not just its fallback branches.
@Suite("SessionStore integration (full lifecycle + simulated relaunch)")
struct SessionStoreIntegrationTests {
    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Seeds real default `context.md`/`summary_template.md`/`default_watchers.yaml` files under
    /// `root`, then builds a `SessionStore` pointed at them plus `root/sessions`, mirroring how
    /// `AppConfig.shared` would wire this up in the real app (section 1.1/14).
    private func makeStoreWithRealDefaults(root: URL, metaFlushInterval: TimeInterval = 5.0) throws -> SessionStore {
        let contextURL = root.appendingPathComponent("context/common.md")
        let templateURL = root.appendingPathComponent("templates/summary.md")
        let enabledWatchersURL = root.appendingPathComponent("default_watchers.yaml")

        try FileManager.default.createDirectory(at: contextURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: templateURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        try "# 参加者\n- 田中さん、佐藤さん\n# アジェンダ\n- 見積提示\n".write(to: contextURL, atomically: true, encoding: .utf8)
        try "# {{title}}\n\n## ヒアリング内容\n\n## 提示した見積\n".write(to: templateURL, atomically: true, encoding: .utf8)
        try "enabled:\n  - pre-check\n  - action-items\n".write(to: enabledWatchersURL, atomically: true, encoding: .utf8)

        return SessionStore(
            sessionsRootDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            defaultContextFileURL: contextURL,
            defaultSummaryTemplateFileURL: templateURL,
            defaultEnabledWatchersFileURL: enabledWatchersURL,
            metaFlushInterval: metaFlushInterval
        )
    }

    private func makeRefinedSegment(from segment: TranscriptSegment, batchId: String) -> RefinedSegment {
        RefinedSegment(
            id: segment.id,
            startMs: segment.startMs,
            endMs: segment.endMs,
            speaker: segment.speaker,
            rawText: segment.text,
            refinedText: segment.text.trimmingCharacters(in: .whitespaces) + "。",
            error: nil,
            refinedAt: Date(),
            model: "claude-haiku-4-5-20251001",
            batchId: batchId
        )
    }

    @Test(
        """
        Full meeting lifecycle (Draft -> Recording -> Ended) survives a simulated app relaunch: \
        meta.json, transcript.jsonl/refined.jsonl, context.md/summary_template.md, summary.state.json/summary.md, \
        and watchers/* all round-trip through a brand-new SessionStore instance pointed at the same directory
        """
    )
    func fullLifecycleSurvivesSimulatedRelaunch() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // --- Run 1: what a Session Window would do over the course of one real meeting ---
        let store = try makeStoreWithRealDefaults(root: root, metaFlushInterval: 0.05)

        // 1. Draft: window opens, seeds context/template/enabled watchers from the real defaults.
        let created = try await store.createDraftSession()
        #expect(created.state == .draft)
        #expect(created.segmentCount == 0)

        let draftHandle = try await store.openSession(created.id)
        #expect(await draftHandle.readContext().contains("見積提示"))
        #expect(await draftHandle.readSummaryTemplate().contains("ヒアリング内容"))
        #expect(try await draftHandle.readEnabledWatchers() == ["pre-check", "action-items"])

        // User edits Prep-tab context before recording starts (kikimi.md 4 章: editable anytime).
        try await draftHandle.writeContext("# 参加者\n- 田中さん、佐藤さん、鈴木さん（追加）\n# アジェンダ\n- 見積提示\n- 次回日程")

        // 2. Draft -> Recording. `beginRecording` both flips state/startedAt and hands back the same
        // handle `openSession` would.
        let recordingHandle = try await store.beginRecording(created.id)
        let recordingId = await store.recordingSessionId
        #expect(recordingId == created.id)
        #expect(await recordingHandle.meta.state == .recording)
        #expect(await recordingHandle.meta.startedAt != nil)

        // A second Draft session cannot start recording while this one is active (section 9).
        let secondDraft = try await store.createDraftSession()
        await #expect(throws: SessionStoreError.anotherSessionRecording(activeSessionId: created.id)) {
            try await store.beginRecording(secondDraft.id)
        }

        // 3. Recording: real STT-pipeline-shaped traffic. Interleave mic/system segments the way
        // `02-stt-pipeline.md`'s merged Segment Queue would, appending transcript first and refined
        // segments for a trailing subset (as `03-refinement-batch.md`'s batch refiner would, lagging
        // behind raw transcription) to also exercise `refinedCount` independently of `segmentCount`.
        var transcriptSegments: [TranscriptSegment] = []
        for i in 0..<12 {
            let source: AudioSourceKind = i.isMultiple(of: 2) ? .mic : .system
            let segment = try await recordingHandle.appendTranscriptSegment(
                source: source,
                startMs: i * 1_000,
                endMs: i * 1_000 + 800,
                text: "発言 \(i)",
                confidence: 0.9
            )
            transcriptSegments.append(segment)
        }
        #expect(transcriptSegments.map(\.id) == (1...12).map { "seg_" + String(format: "%05d", $0) })

        for segment in transcriptSegments.prefix(10) {
            try await recordingHandle.appendRefinedSegment(makeRefinedSegment(from: segment, batchId: "batch_00001"))
        }
        // One refinement failure, per kikimi.md 5 章's documented failure shape (`refined_text: null`),
        // still counts as an attempted refinement (section 5.2: "整形失敗... の場合も... カウントする").
        try await recordingHandle.appendRefinedSegment(
            RefinedSegment(
                id: transcriptSegments[10].id,
                startMs: transcriptSegments[10].startMs,
                endMs: transcriptSegments[10].endMs,
                speaker: transcriptSegments[10].speaker,
                rawText: transcriptSegments[10].text,
                refinedText: nil,
                error: "LLM request timed out",
                refinedAt: Date(),
                model: "claude-haiku-4-5-20251001",
                batchId: "batch_00002"
            )
        )

        // `metaFlushInterval` is tiny (0.05s) here specifically so this sleep-then-flush exercises the
        // throttled counter-write path (section 7) against a real wall clock, rather than only the
        // deterministic `MutableClock` unit tests in `SessionHandleTests.swift` already cover.
        try await Task.sleep(nanoseconds: 100_000_000)
        try await recordingHandle.flush()

        // `04-summary-updater.md`/`05-watcher-runner.md`-shaped generic-storage writes during Recording.
        struct FakeSummaryState: Codable, Equatable {
            var title: String
            var overview: String
        }
        let summaryState = FakeSummaryState(title: "デイリースクラム", overview: "見積提示について協議した。")
        try await recordingHandle.writeJSON(summaryState, to: .summaryState)
        try await recordingHandle.writeText("# デイリースクラム\n\n## 概要\n\n見積提示について協議した。\n", to: .summaryMarkdown)
        try await recordingHandle.writeText("---\nid: risk-check\n---\n\n# System\n\nリスクを検出する。\n", to: .watcherDefinition(id: "risk-check"))
        try await recordingHandle.writeJSON(["items": []] as [String: [String]], to: .watcherState(id: "risk-check"))
        try await recordingHandle.writeEnabledWatchers(["pre-check", "action-items", "risk-check"])

        // 4. Recording -> Ended.
        try await store.endMeeting(created.id)
        let recordingIdAfterEnd = await store.recordingSessionId
        #expect(recordingIdAfterEnd == nil)
        #expect(await recordingHandle.meta.state == .ended)
        #expect(await recordingHandle.meta.endedAt != nil)
        #expect(await recordingHandle.meta.durationMs >= 0)

        // Exclusivity is released: the second Draft session can now start recording.
        _ = try await store.beginRecording(secondDraft.id)
        try await store.endMeeting(secondDraft.id)

        // --- Simulate an app relaunch: a brand-new SessionStore, no cached SessionHandle, same disk root. ---
        let relaunchedStore = try makeStoreWithRealDefaults(root: root, metaFlushInterval: 5.0)

        let sessionsAfterRelaunch = await relaunchedStore.listSessions()
        #expect(sessionsAfterRelaunch.contains { $0.id == created.id })
        #expect(sessionsAfterRelaunch.contains { $0.id == secondDraft.id })

        let reopenedHandle = try await relaunchedStore.openSession(created.id)
        let reloadedMeta = await reopenedHandle.meta
        #expect(reloadedMeta.state == .ended)
        #expect(reloadedMeta.segmentCount == 12)
        #expect(reloadedMeta.refinedCount == 11)

        // The persisted counters must match the *actual* line counts on disk (design doc section 13's
        // explicit layer-1 invariant, re-checked here after a real relaunch rather than within one
        // still-warm process).
        let reloadedTranscript = try await reopenedHandle.readTranscriptSegments()
        let reloadedRefined = try await reopenedHandle.readRefinedSegments()
        #expect(reloadedTranscript.count == reloadedMeta.segmentCount)
        #expect(reloadedRefined.count == reloadedMeta.refinedCount)
        #expect(reloadedTranscript == transcriptSegments)
        #expect(reloadedRefined.first { $0.refinedText == nil }?.error == "LLM request timed out")

        // Prep-tab edits made mid-Recording persisted (writeContext is always-immediate, section 8).
        #expect(await reopenedHandle.readContext().contains("鈴木さん（追加）"))

        // Generic-storage primitives (summary/watchers) round-trip through the relaunch too.
        let reloadedSummaryState = try await reopenedHandle.readJSON(.summaryState, as: FakeSummaryState.self)
        #expect(reloadedSummaryState == summaryState)
        let reloadedSummaryMarkdown = try await reopenedHandle.readText(.summaryMarkdown)
        #expect(reloadedSummaryMarkdown?.contains("見積提示について協議した。") == true)
        let reloadedWatcherDefinition = try await reopenedHandle.readText(.watcherDefinition(id: "risk-check"))
        #expect(reloadedWatcherDefinition?.contains("id: risk-check") == true)
        let reloadedEnabledWatchers = try await reopenedHandle.readEnabledWatchers()
        #expect(reloadedEnabledWatchers == ["pre-check", "action-items", "risk-check"])
        let sessionLocalWatcherIds = try await reopenedHandle.listSessionLocalWatcherIds()
        #expect(sessionLocalWatcherIds == ["risk-check"])

        // Finally: Ended sessions can be deleted, and deletion actually removes the folder from disk.
        let directoryURL = root.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(created.id, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: directoryURL.path))
        try await relaunchedStore.deleteSession(created.id)
        #expect(!FileManager.default.fileExists(atPath: directoryURL.path))
    }

    @Test("A session left .recording by a simulated crash is detected and finalized by a freshly relaunched SessionStore")
    func crashDuringRecordingIsRecoveredAfterRelaunch() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // --- Run 1: recording starts, some segments land on disk, then the process "crashes" (no endRecording). ---
        let store = try makeStoreWithRealDefaults(root: root)
        let meta = try await store.createDraftSession()
        let handle = try await store.beginRecording(meta.id)

        for i in 0..<5 {
            try await handle.appendTranscriptSegment(source: .mic, startMs: i * 1_000, endMs: i * 1_000 + 700, text: "発言 \(i)", confidence: 0.85)
        }
        try await handle.flush()
        // No `endRecording` call: `meta.json` is left on disk with `state == .recording`, exactly as a
        // force-quit mid-meeting would leave it (kikimi.md 15 章 Open Questions).

        // --- Simulate relaunch: brand-new SessionStore, startup crash-recovery pass. ---
        let relaunchedStore = try makeStoreWithRealDefaults(root: root)
        let incomplete = await relaunchedStore.detectIncompleteSessions()
        #expect(incomplete.map(\.id) == [meta.id])

        let recovered = try await relaunchedStore.finalizeCrashedSession(meta.id)
        // Crash recovery lands on .paused, not .ended (kikimi.md 15 章): a crash is not the user
        // deciding the meeting is over, so the session stays resumable/endable.
        #expect(recovered.state == .paused)
        #expect(recovered.durationMs == 4_700) // last segment's endMs, per section 10's estimation rule
        #expect(recovered.endedAt == nil)
        #expect(recovered.recordings.last?.endedAt != nil)

        // The recovered state is itself durable: re-reading via yet another fresh store still sees .paused.
        let doubleCheckStore = try makeStoreWithRealDefaults(root: root)
        let doubleCheckSessions = await doubleCheckStore.listSessions()
        #expect(doubleCheckSessions.first { $0.id == meta.id }?.state == .paused)
        #expect(await doubleCheckStore.detectIncompleteSessions().isEmpty)
    }
}
