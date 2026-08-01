import Foundation
import Testing

@testable import Kikimi

/// `SummaryPromptBuilder` coverage (`docs/design/04-summary-updater.md` §4.4, kikimi.md 8 章
/// 「LLM への入出力の例」).
@Suite("SummaryPromptBuilder")
struct SummaryPromptBuilderTests {
    @Test("patch contract is fixed and mentions the patch-only, null-if-unchanged structural rules")
    func patchContractIsFixedAndMentionsStructuralRules() {
        let contract = SummaryPromptBuilder.patchContract

        #expect(contract.contains("変更差分（patch）"))
        #expect(contract.contains("何も変更がなければ全フィールド null"))
    }

    @Test("systemPrompt(policyBody:) reconstructs the policy layer and the fixed patch-contract layer")
    func systemPromptReconstructsPolicyAndContractLayers() {
        let policyBody = "あなたは会議サマリを更新するエディタです。"

        let prompt = SummaryPromptBuilder.systemPrompt(policyBody: policyBody)

        #expect(prompt == policyBody + "\n\n【patch 契約】\n" + SummaryPromptBuilder.patchContract)
        #expect(prompt.hasPrefix(policyBody))
        #expect(prompt.contains("【patch 契約】"))
    }

    @Test("user prompt embeds the current state, segments in seg_XXXXX (speaker): text form, and the given timestamp")
    func userPromptEmbedsStateSegmentsAndTimestamp() throws {
        var state = SummaryState.empty
        state.title = "デイリースクラム"
        state.overview = "既存概要"

        let segments = [
            SummarySegmentInput(id: "seg_00350", startMs: 100, speaker: .mic, text: "最初の発言"),
            SummarySegmentInput(id: "seg_00351", startMs: 200, speaker: .system, text: "了解しました")
        ]

        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 1
        components.hour = 14
        components.minute = 52
        components.second = 0
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(utcCalendar.date(from: components))

        let userPrompt = try SummaryPromptBuilder.buildUserPrompt(
            state: state, segments: segments, now: now, contextMarkdown: "# 参加者\n- 田中さん"
        )

        #expect(userPrompt.contains("\"title\" : \"デイリースクラム\"") || userPrompt.contains("\"title\":\"デイリースクラム\""))
        #expect(userPrompt.contains("既存概要"))
        #expect(userPrompt.contains("seg_00350 (mic): 最初の発言"))
        #expect(userPrompt.contains("seg_00351 (system): 了解しました"))
        // seg_00350 appears before seg_00351 (startMs ascending, as passed in by the caller).
        let firstIndex = try #require(userPrompt.range(of: "seg_00350"))
        let secondIndex = try #require(userPrompt.range(of: "seg_00351"))
        #expect(firstIndex.lowerBound < secondIndex.lowerBound)
        #expect(userPrompt.contains("2026-07-01T14:52:00Z"))
        #expect(userPrompt.contains("田中さん"))
    }

    @Test("does not call Date() internally: the same (state, segments, now, context) always produces the same prompt")
    func isPureGivenSameInputs() throws {
        let state = SummaryState.empty
        let segments = [SummarySegmentInput(id: "seg_00001", startMs: 0, speaker: .mic, text: "x")]
        let now = Date(timeIntervalSince1970: 1_751_000_000)

        let first = try SummaryPromptBuilder.buildUserPrompt(state: state, segments: segments, now: now, contextMarkdown: "")
        let second = try SummaryPromptBuilder.buildUserPrompt(state: state, segments: segments, now: now, contextMarkdown: "")

        #expect(first == second)
    }

    @Test("renders an empty segments list as an empty conversation block without crashing")
    func rendersEmptySegmentsList() throws {
        let userPrompt = try SummaryPromptBuilder.buildUserPrompt(
            state: .empty, segments: [], now: Date(timeIntervalSince1970: 0), contextMarkdown: ""
        )

        #expect(userPrompt.contains("【直近の会話】"))
    }

    @Test("buildFinalRevisionUserPrompt embeds context, the full state as JSON (including topics), and seg lines in startMs order")
    func finalRevisionPromptEmbedsContextStateAndTranscript() throws {
        var state = SummaryState.empty
        state.title = "定例会議"
        state.overview = "既存の概要"
        state.topics = [
            SummaryState.Topic(
                id: "tp_001", heading: "検索基盤の移行方針", body: "- 移行先は X にする", sourceSegIds: ["seg_00001"]
            )
        ]

        let segments = [
            SummarySegmentInput(id: "seg_00001", startMs: 0, speaker: .mic, text: "最初の発言"),
            SummarySegmentInput(id: "seg_00002", startMs: 100, speaker: .system, text: "了解しました")
        ]

        let prompt = try SummaryPromptBuilder.buildFinalRevisionUserPrompt(
            state: state, segments: segments, contextMarkdown: "# 参加者\n- 田中さん"
        )

        #expect(prompt.contains("【事前知識】"))
        #expect(prompt.contains("田中さん"))
        #expect(prompt.contains("【現在の state】"))
        #expect(prompt.contains("\"topics\""))
        #expect(prompt.contains("検索基盤の移行方針"))
        #expect(prompt.contains("【会議全体の書き起こし】"))
        #expect(prompt.contains("seg_00001 (mic): 最初の発言"))
        #expect(prompt.contains("seg_00002 (system): 了解しました"))
        let firstIndex = try #require(prompt.range(of: "seg_00001"))
        let secondIndex = try #require(prompt.range(of: "seg_00002"))
        #expect(firstIndex.lowerBound < secondIndex.lowerBound)
    }

    @Test("buildFinalRevisionUserPrompt truncates the oldest transcript lines when the char budget is exceeded, but never truncates state")
    func finalRevisionPromptTruncatesOldestSegmentsWhenBudgetExceeded() throws {
        var state = SummaryState.empty
        state.overview = "STATE_MARKER_保持されるべき概要"

        let oldestText = "OLDEST_SEGMENT_TEXT"
        let newestText = "NEWEST_SEGMENT_TEXT"
        var segments = [SummarySegmentInput(id: "seg_00000", startMs: 0, speaker: .mic, text: oldestText)]
        let padding = String(repeating: "あ", count: 2_000)
        for index in 1...100 {
            segments.append(
                SummarySegmentInput(
                    id: "seg_\(String(format: "%05d", index))", startMs: index * 1_000, speaker: .mic, text: padding
                )
            )
        }
        segments.append(SummarySegmentInput(id: "seg_99999", startMs: 999_000, speaker: .mic, text: newestText))

        let prompt = try SummaryPromptBuilder.buildFinalRevisionUserPrompt(
            state: state, segments: segments, contextMarkdown: ""
        )

        // state is never subject to the transcript budget, so its marker always survives.
        #expect(prompt.contains("STATE_MARKER_保持されるべき概要"))
        // The oldest segment line was dropped by the front-truncation, the newest was kept.
        #expect(!prompt.contains(oldestText))
        #expect(prompt.contains(newestText))
    }
}
