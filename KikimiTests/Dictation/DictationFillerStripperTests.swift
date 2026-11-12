import Foundation
import Testing

@testable import Kikimi

/// `docs/design/49-dictation-filler-strip.md` §6's layer-1 table for the pure filler stripper.
@Suite("DictationFillerStripper")
struct DictationFillerStripperTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let input: String
        let expected: String
        var testDescription: String { input }
    }

    @Test("fillers at a clause boundary are removed together with their comma (FS3)", arguments: [
        Case(input: "えっと、今日の予定です", expected: "今日の予定です"),
        Case(input: "えーと今日の予定です", expected: "今日の予定です"),
        Case(input: "えーっと、今日の予定です", expected: "今日の予定です"),
        Case(input: "ええっと今日の予定です", expected: "今日の予定です"),
        Case(input: "します。なので、えっと分けるのはどうでしょうか", expected: "します。なので、分けるのはどうでしょうか"),
        Case(input: "ええと、確認します", expected: "確認します"),
        Case(input: "えー、本日の議題です", expected: "本日の議題です"),
        Case(input: "えー本日の議題です", expected: "本日の議題です"),
        Case(input: "え、50分というのがノイズになる、え、全体を包むような", expected: "50分というのがノイズになる、全体を包むような"),
        Case(input: "見える。ええ、本当の問題を見つけ出す", expected: "見える。本当の問題を見つけ出す"),
        Case(input: "なっています。えキックオフの概要を", expected: "なっています。キックオフの概要を"),
        Case(input: "したがって、え私の考えとしては", expected: "したがって、私の考えとしては"),
        Case(input: "一行目です。\nえ、二行目です", expected: "一行目です。\n二行目です"),
        Case(input: "終わりです。 えっと、次です", expected: "終わりです。 次です")
    ])
    func boundaryFillersAreRemoved(testCase: Case) {
        #expect(DictationFillerStripper.strip(testCase.input) == testCase.expected)
    }

    @Test("えっと in the middle of a clause is removed and a following comma is kept (FS4)", arguments: [
        Case(input: "これはえっと明日です", expected: "これは明日です"),
        Case(input: "これはえーと、明日です", expected: "これは、明日です"),
        Case(input: "ちょっとえっと会議の方に", expected: "ちょっと会議の方に")
    ])
    func inlineFillersAreRemoved(testCase: Case) {
        #expect(DictationFillerStripper.strip(testCase.input) == testCase.expected)
    }

    @Test("chained fillers are removed in one call")
    func chainedFillersAreRemoved() {
        #expect(DictationFillerStripper.strip("えっと、え、ええ、今日は晴れです") == "今日は晴れです")
        #expect(DictationFillerStripper.strip("あ、はい、えっとえっとバックします") == "あ、はい、バックします")
    }

    @Test("anything with a possible meaningful reading is left untouched (FS2)", arguments: [
        // Surprise / asking back.
        "え？本当ですか",
        "えー！そうなんですか",
        "ええ！？",
        "えーっ、そうなの",
        // `え` followed by hiragana cannot be told apart from a word.
        "えそうなんですか",
        "というえその枠",
        // Mid-clause `え` / `えー` without a boundary.
        "推測のえ根拠も書いて",
        "共有権限とえー権限の組み合わせ",
        // Kansai `ええ` (= いい).
        "ええ感じに仕上がりました",
        "それでええと思います",
        "ええと思います",
        "ええ会議でした",
        // Okurigana and words ending in `え`.
        "考え、まとめます",
        "いいえ、違います",
        "とはいえ、難しいです",
        "彼に言えっと言われた",
        "考ええっと",
        "へえー、すごい",
        // Fillers this type never touches.
        "あの件ですが、まあ、なんかその、こういう感じです",
        "あ、いや、今のはそのままで",
        "はい、うん、そうです"
    ])
    func ambiguousTextIsKept(input: String) {
        #expect(DictationFillerStripper.strip(input) == input)
    }

    @Test("an utterance that is nothing but fillers is returned as spoken (FS5)", arguments: [
        "えっと",
        "えっと。",
        "え、",
        "えーと、ええ、",
        ""
    ])
    func fillerOnlyUtteranceIsKept(input: String) {
        #expect(DictationFillerStripper.strip(input) == input)
    }
}
