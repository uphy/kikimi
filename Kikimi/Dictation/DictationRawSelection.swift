import Foundation

// MARK: - DictationRawSource

/// Which decoder produced the utterance's confirmed raw text
/// (`docs/design/31-dictation-two-pass-decode.md` TP2/TP7).
enum DictationRawSource: Equatable, Sendable {
    /// The key-up batch re-decode (Parakeet, full-utterance context) -- the preferred source.
    case batch
    /// The streaming decoder's `finishUtterance()` text -- the fallback when batch is unavailable
    /// (not warmed, decode failed, produced only whitespace) or two-pass decode is off.
    case streaming
}

// MARK: - DictationRawSelection

/// Pure raw-text selection for the two-pass dictation design
/// (`docs/design/31-dictation-two-pass-decode.md` §3.3): decides, once per utterance, which
/// decoder's output becomes the confirmed `raw_text` handed to refinement/insertion. Split out of
/// `DictationController` so the batch-over-streaming precedence (TP2) and the "both empty means no
/// utterance" rule (design 29 DH10, unchanged) are testable without any controller state.
struct DictationRawSelection: Equatable, Sendable {
    /// The confirmed raw text: trimmed and guaranteed non-empty (a `nil` selection is how "both
    /// decoders produced nothing" is represented, so callers keep the existing DH10 empty-utterance
    /// path in one place instead of re-checking `rawText.isEmpty`).
    var rawText: String
    var source: DictationRawSource
    /// The trimmed streaming text, kept for `entry.json`'s `streaming_text` diagnostic (TP7). Only
    /// non-`nil` when `source == .batch` *and* the streaming decoder produced something -- when
    /// streaming itself is the source, `rawText` already is the streaming text, and recording it
    /// twice would carry no diagnostic value.
    var streamingText: String?

    /// TP2's precedence: a non-whitespace batch result wins; otherwise fall back to the streaming
    /// text; `nil` when both trim to empty (the utterance is discarded, DH10).
    static func select(batchText: String?, streamingText: String) -> DictationRawSelection? {
        let trimmedBatch = batchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedStreaming = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedBatch.isEmpty {
            return DictationRawSelection(
                rawText: trimmedBatch,
                source: .batch,
                streamingText: trimmedStreaming.isEmpty ? nil : trimmedStreaming
            )
        }
        guard !trimmedStreaming.isEmpty else {
            return nil
        }
        return DictationRawSelection(rawText: trimmedStreaming, source: .streaming, streamingText: nil)
    }
}
