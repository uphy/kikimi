import Foundation

// MARK: - DictationFillerStripper

/// Rule-based removal of Japanese fillers from a dictated utterance, applied to the confirmed raw
/// text before the (optional) LLM refinement (`docs/design/49-dictation-filler-strip.md`).
///
/// The rules are deliberately narrow: a filler is removed only where the surrounding characters
/// rule out a meaningful reading, and everything ambiguous is left in place (FS2). `あの` / `まあ` /
/// `なんか` / `その` / `こう` are never touched -- they are indistinguishable from their lexical uses
/// without context (§2's measurements).
enum DictationFillerStripper {
    /// Returns `text` with fillers removed, or `text` unchanged when nothing matched or when
    /// stripping would leave no letters or digits (FS5: an utterance that is nothing but fillers is
    /// inserted as spoken rather than silently swallowed).
    static func strip(_ text: String) -> String {
        var current = text
        // A removal can expose the next filler ("えっと、え、今日は"), so repeat until stable. The
        // bound only guards against a rule that fails to shrink the string; real inputs settle in
        // two or three passes.
        for _ in 0..<maxPasses {
            let next = applyOnce(current)
            if next == current { break }
            current = next
        }
        guard current != text else { return text }
        guard containsContent(current) else { return text }
        return current
    }

    // MARK: - Rules

    private static let maxPasses = 8

    private static let comma = "[、,，]"
    /// Kanji, katakana, Latin letters and digits. The prolonged sound mark `ー` is deliberately not
    /// in this class, so `え` followed by `ー` is left to the `えー` rule.
    private static let nonHiraganaLetter = "[一-龥々〆ァ-ヺA-Za-zＡ-Ｚａ-ｚ0-9０-９]"

    /// FS3: fillers at a clause boundary (start of text, or right after `。？！?!`, a newline or a
    /// comma). The boundary and any spaces after it are captured and kept; the filler and a comma
    /// directly after it are dropped.
    ///
    /// Alternatives, longest first:
    /// - `えっと` / `えーと` / `えーっと` / `ええっと` / `ええーと`
    /// - `ええと` only when a comma or the end of the text follows (`ええと思う` is Kansai for
    ///   `いいと思う`)
    /// - `えー` unless `？！` follows (`えー！` is surprise, not hesitation)
    /// - `ええ` only when a comma follows (`ええ感じ` is Kansai for `いい感じ`)
    /// - `え` when a comma or a non-hiragana letter follows (`え？` and `えそう` are kept)
    private static let boundaryRule = makeRegex(
        "(^|[。？！?!\\n、,，])([ 　]*)"
            + "(?:"
            + "ええ?(?:ー+っ?|っ)と\(comma)?"
            + "|ええと(?:\(comma)|$)"
            + "|えー+(?![とっー？！?!])\(comma)?"
            + "|ええ\(comma)"
            + "|え(?:\(comma)|(?=\(nonHiraganaLetter)))"
            + ")[ 　]*"
    )

    /// FS4: `えっと` / `えーと` / `えーっと` in the middle of a clause ("これはえっと明日です"). Skipped
    /// right after a kanji, where `え` may be okurigana ("考え"), and right after `え`, where the
    /// first `え` may belong to the preceding word. A comma after the filler is kept, since here it
    /// may be the clause's own.
    private static let inlineRule = makeRegex("(?<![一-龥々〆えぇ])え(?:ー+っ?|っ)と")

    private static let contentRule = makeRegex("[ぁ-ゖァ-ヺ一-龥々〆A-Za-zＡ-Ｚａ-ｚ0-9０-９]")

    private static func applyOnce(_ text: String) -> String {
        let afterBoundary = replace(boundaryRule, in: text, with: "$1$2")
        return replace(inlineRule, in: afterBoundary, with: "")
    }

    private static func containsContent(_ text: String) -> Bool {
        contentRule.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        // The patterns are compile-time constants; a failure here is a programming error that the
        // unit tests catch on first use.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }
}
