import Foundation

// MARK: - PromptPlaceholder

/// Shared single-pass `{{token}}` substitution helper (`docs/design/42-prompt-overrides.md` §4.1).
/// Extracted from `WatcherPromptBuilder.buildUserPrompt` (`docs/design/05-watcher-runner.md` §6), which
/// now delegates to `expand(template:replacements:)` -- behavior is unchanged, only the implementation
/// moved so other builders (e.g. `SimpleWatcherSpec.systemPrompt`) can share it.
enum PromptPlaceholder {
    /// Expands every `(token, replacement)` pair in `replacements` within `template`, scanning the
    /// *original* template text once, left to right ("置換は 1 パスで行う"). Deliberately not a sequence
    /// of `replacingOccurrences(of:with:)` calls: a replacement's text could -- in principle -- itself
    /// contain another token's literal text, and a sequential replace would then wrongly re-expand it.
    /// Scanning the original template once and copying substituted text through untouched avoids that
    /// class of bug entirely. Tokens not present in `replacements` (any other `{{...}}`-shaped text) are
    /// left untouched -- this is plain string replacement, not Mustache.
    static func expand(template: String, replacements: [(token: String, replacement: String)]) -> String {
        var result = ""
        var remaining = Substring(template)
        while !remaining.isEmpty {
            var earliestMatch: (range: Range<Substring.Index>, replacement: String)?
            for (token, replacement) in replacements {
                guard let range = remaining.range(of: token) else { continue }
                if earliestMatch == nil || range.lowerBound < earliestMatch!.range.lowerBound {
                    earliestMatch = (range, replacement)
                }
            }
            guard let match = earliestMatch else {
                result += remaining
                break
            }
            result += remaining[remaining.startIndex..<match.range.lowerBound]
            result += match.replacement
            remaining = remaining[match.range.upperBound...]
        }
        return result
    }
}
