import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `CompactTicker.text(rows:micVolatileText:systemVolatileText:)`
/// (`Kikimi/Views/MeetingWorkspace/CompactRecordingBarView.swift`,
/// `docs/design/18-recording-window-stow-and-compact.md` §3.4/§5.3/§7).
///
/// Pure/`SwiftUI`-free by design (same rationale as `TranscriptRowList`,
/// `KikimiTests/ViewModels/TranscriptRowListTests.swift`), so every priority branch is exercised
/// directly here without touching `MeetingWorkspaceViewModel` or any AppKit machinery.
@Suite("CompactTicker")
struct CompactTickerTests {
    private func row(
        _ id: String,
        startMs: Int = 0,
        rawText: String,
        state: TranscriptRowState
    ) -> TranscriptRowViewModel {
        TranscriptRowViewModel(id: id, startMs: startMs, endMs: startMs + 1_000, speaker: .mic, rawText: rawText, state: state)
    }

    // MARK: - Volatile text takes priority over any confirmed row

    @Test("a non-empty mic volatile text wins over everything else, including a non-empty system volatile text")
    func micVolatileTextWinsOverSystemVolatileAndRows() {
        let rows = [row("seg_00001", rawText: "確定済みの行", state: .refined("確定済みの行"))]
        let text = CompactTicker.text(rows: rows, micVolatileText: "マイクの途中経過", systemVolatileText: "システムの途中経過")
        #expect(text == "マイクの途中経過")
    }

    @Test("a non-empty system volatile text is used when mic volatile text is empty")
    func systemVolatileTextUsedWhenMicVolatileIsEmpty() {
        let rows = [row("seg_00001", rawText: "確定済みの行", state: .refined("確定済みの行"))]
        let text = CompactTicker.text(rows: rows, micVolatileText: "", systemVolatileText: "システムの途中経過")
        #expect(text == "システムの途中経過")
    }

    @Test("both volatile texts empty falls through to the last confirmed row")
    func bothVolatileTextsEmptyFallsThroughToRows() {
        let rows = [row("seg_00001", rawText: "raw", state: .refined("整形済みテキスト"))]
        let text = CompactTicker.text(rows: rows, micVolatileText: "", systemVolatileText: "")
        #expect(text == "整形済みテキスト")
    }

    // MARK: - Confirming text (the two-pass re-decode gap)

    @Test("confirming text keeps the ticker forward instead of falling back to the previous row while the re-decode runs")
    func confirmingTextBeatsThePreviousRow() {
        let rows = [row("seg_00001", rawText: "ひとつ前の行", state: .refined("ひとつ前の行"))]
        let text = CompactTicker.text(
            rows: rows,
            micVolatileText: "",
            systemVolatileText: "",
            micConfirmingText: "確定したが行が未着。"
        )
        #expect(text == "確定したが行が未着。")
    }

    @Test("confirming and volatile text of the same source are shown as one line, confirming first")
    func confirmingAndVolatileAreConcatenated() {
        let text = CompactTicker.text(
            rows: [],
            micVolatileText: "続きを話している",
            systemVolatileText: "",
            micConfirmingText: "確定した文。"
        )
        #expect(text == "確定した文。続きを話している")
    }

    @Test("a system-only confirming text is used when mic has neither half")
    func systemConfirmingTextUsedWhenMicIsEmpty() {
        let rows = [row("seg_00001", rawText: "ひとつ前の行", state: .raw)]
        let text = CompactTicker.text(
            rows: rows,
            micVolatileText: "",
            systemVolatileText: "",
            micConfirmingText: "",
            systemConfirmingText: "システム側の確定文。"
        )
        #expect(text == "システム側の確定文。")
    }

    // MARK: - Confirmed-row fallback: refined ?? raw

    @Test("the last row's refined text is used when non-empty")
    func lastRowRefinedTextIsUsed() {
        let rows = [
            row("seg_00001", startMs: 0, rawText: "1つ目", state: .refined("1つ目・整形済み")),
            row("seg_00002", startMs: 1_000, rawText: "2つ目", state: .refined("2つ目・整形済み"))
        ]
        let text = CompactTicker.text(rows: rows, micVolatileText: "", systemVolatileText: "")
        #expect(text == "2つ目・整形済み")
    }

    @Test("a .raw row falls back to rawText (not yet refined)")
    func rawRowFallsBackToRawText() {
        let rows = [row("seg_00001", rawText: "まだ整形されていない生テキスト", state: .raw)]
        let text = CompactTicker.text(rows: rows, micVolatileText: "", systemVolatileText: "")
        #expect(text == "まだ整形されていない生テキスト")
    }

    @Test(".refining falls back to rawText")
    func refiningRowFallsBackToRawText() {
        let rows = [row("seg_00001", rawText: "整形キュー待ちの生テキスト", state: .refining)]
        let text = CompactTicker.text(rows: rows, micVolatileText: "", systemVolatileText: "")
        #expect(text == "整形キュー待ちの生テキスト")
    }

    @Test(".refinedFailed falls back to rawText (kikimi.md 8.5 章's raw fallback)")
    func refinedFailedRowFallsBackToRawText() {
        let rows = [row("seg_00001", rawText: "整形失敗時のフォールバック", state: .refinedFailed("API error"))]
        let text = CompactTicker.text(rows: rows, micVolatileText: "", systemVolatileText: "")
        #expect(text == "整形失敗時のフォールバック")
    }

    // MARK: - Skipped rows: dropped-as-meaningless (empty refined_text) and merged-away

    @Test("a trailing row dropped by refinement (empty refined_text) is skipped in favor of an earlier row")
    func trailingDroppedRowIsSkipped() {
        let rows = [
            row("seg_00001", startMs: 0, rawText: "意味のある発話", state: .refined("意味のある発話・整形済み")),
            row("seg_00002", startMs: 1_000, rawText: "えーと", state: .refined("")) // dropped as meaningless
        ]
        let text = CompactTicker.text(rows: rows, micVolatileText: "", systemVolatileText: "")
        #expect(text == "意味のある発話・整形済み")
    }

    @Test("a trailing row merged into an earlier leader row is skipped in favor of an earlier row")
    func trailingMergedAwayRowIsSkipped() {
        let rows = [
            row("seg_00001", startMs: 0, rawText: "リーダー行", state: .refined("リーダー行・整形済み")),
            row("seg_00002", startMs: 1_000, rawText: "続きの断片", state: .mergedInto(leaderId: "seg_00001"))
        ]
        let text = CompactTicker.text(rows: rows, micVolatileText: "", systemVolatileText: "")
        #expect(text == "リーダー行・整形済み")
    }

    @Test("multiple trailing skipped rows (dropped + merged-away) are both skipped to reach the real last row")
    func multipleTrailingSkippedRowsAreAllSkipped() {
        let rows = [
            row("seg_00001", startMs: 0, rawText: "本当の最後の行", state: .refined("本当の最後の行・整形済み")),
            row("seg_00002", startMs: 1_000, rawText: "続きの断片", state: .mergedInto(leaderId: "seg_00001")),
            row("seg_00003", startMs: 2_000, rawText: "えーと、あの", state: .refined(""))
        ]
        let text = CompactTicker.text(rows: rows, micVolatileText: "", systemVolatileText: "")
        #expect(text == "本当の最後の行・整形済み")
    }

    @Test("every row skipped (all dropped/merged-away) with no volatile text yields nil")
    func everyRowSkippedYieldsNil() {
        let rows = [
            row("seg_00001", startMs: 0, rawText: "えーと", state: .refined("")),
            row("seg_00002", startMs: 1_000, rawText: "続き", state: .mergedInto(leaderId: "seg_00003"))
        ]
        let text = CompactTicker.text(rows: rows, micVolatileText: "", systemVolatileText: "")
        #expect(text == nil)
    }

    // MARK: - Nil (nothing to show)

    @Test("an empty rows list with no volatile text yields nil")
    func emptyRowsAndEmptyVolatileYieldsNil() {
        let text = CompactTicker.text(rows: [], micVolatileText: "", systemVolatileText: "")
        #expect(text == nil)
    }
}
