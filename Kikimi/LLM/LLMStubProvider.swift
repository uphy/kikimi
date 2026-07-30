import Foundation

// MARK: - LLMStubProvider

/// Implements `KIKIMI_STUB_LLM=1` stub-mode dispatch (`docs/design/12-llm-client.md` section 5):
/// bypasses `LLMProcessRunner` entirely and returns a fixed JSON response keyed by
/// `LLMRequest.stubKey`, so `kikimi-verify` / integration tests can drive SummaryUpdater / title /
/// UI logic end-to-end without spending Claude Max quota or requiring network access.
struct LLMStubProvider: Sendable {
    let isEnabled: Bool

    /// `stubKey -> raw JSON` map loaded from `KIKIMI_STUB_LLM_FILE` (section 5: "または環境変数
    /// `KIKIMI_STUB_LLM_FILE` で JSON マップを差し込める"). Empty when the env var is unset or the
    /// file is missing/unreadable. Consulted *before* the `"refinement"` echo stub and
    /// `builtinDefaults` so a caller can override any built-in stub key from the file (including
    /// restoring the old fixed `{"segments": []}` refinement response for tests that specifically
    /// want the raw-fallback path -- 03-refinement-batch.md section 9).
    private let overrides: [String: String]

    /// Built-in `stubKey -> raw JSON` fallback table, consulted only when `overrides` has no entry
    /// for the key and the key isn't `"refinement"` (that one is generated dynamically -- see
    /// `RefinementEchoStub` below).
    ///
    /// `"chat"` (`docs/design/38-session-chat.md` CH11b) has to be here, not just in a
    /// `KIKIMI_STUB_LLM_FILE` fixture: without it every chat send under `KIKIMI_STUB_LLM=1`
    /// (`mise run verify-smoke`, the `kikimi-verify` skill) throws `missingStructuredOutput`. The
    /// canned answer is Markdown so the tab's web-view rendering is exercised too.
    private static let builtinDefaults: [String: String] = [
        "chat": #"{"answer": "[stub] スタブ応答です。\n\n- 実際の LLM は呼ばれていません\n- `KIKIMI_STUB_LLM_FILE` で上書きできます"}"#
    ]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isEnabled = environment["KIKIMI_STUB_LLM"] == "1"
        overrides = Self.loadOverrides(path: environment["KIKIMI_STUB_LLM_FILE"])
    }

    /// - Throws: `LLMClientError.missingStructuredOutput` if `request.stubKey` has no registered
    ///   response (in `overrides`, isn't `"refinement"`, and isn't in `Self.builtinDefaults`),
    ///   `.invalidJSON` if the resolved value is not JSON, `.decodeFailed` if it does not decode into
    ///   `T`.
    func stubResult<T: Decodable & Sendable>(for request: LLMRequest) throws -> LLMResult<T> {
        let rawJSON = try resolveRawJSON(for: request)
        return try Self.decode(rawJSON)
    }

    /// Raw-JSON counterpart of `stubResult(for:)` (`docs/design/05-watcher-runner.md` §5.1): resolves
    /// the exact same `stubKey`/`overrides`/`"refinement"`-echo/`builtinDefaults` dispatch, but skips
    /// the `T` decode entirely and returns the raw bytes -- `WatcherRunner`'s consumer schema is only
    /// known at runtime (`JSONValue`, not a fixed `Decodable`), so it cannot go through
    /// `JSONDecoder`'s `.convertFromSnakeCase` key transform the way `stubResult(for:)` does.
    ///
    /// - Throws: `LLMClientError.missingStructuredOutput` if `request.stubKey` has no registered
    ///   response, `.invalidJSON` if the resolved value is not valid UTF-8.
    func stubRawResult(for request: LLMRequest) throws -> LLMResult<Data> {
        let rawJSON = try resolveRawJSON(for: request)
        guard let data = rawJSON.data(using: .utf8) else {
            throw LLMClientError.invalidJSON(raw: rawJSON)
        }
        return LLMResult(value: data, usage: .zero)
    }

    /// Shared dispatch behind `stubResult(for:)`/`stubRawResult(for:)`: resolves `request.stubKey` to
    /// a raw JSON string via `overrides` first, then the built-in `"refinement"` echo stub, then
    /// `Self.builtinDefaults`, throwing `missingStructuredOutput` if none match.
    private func resolveRawJSON(for request: LLMRequest) throws -> String {
        let key = request.stubKey ?? ""
        if let overrideJSON = overrides[key] {
            return overrideJSON
        }
        if key == "refinement" {
            // Builtin default for the refinement stub key (03-refinement-batch.md section 9): echo
            // every target segment back as "[stub] " + rawText (or "" for the intentional-drop
            // marker), rather than a static empty-segments response, so kikimi-verify / integration
            // tests deterministically exercise RefinementValidator's SUCCESS and DROP paths instead
            // of always hitting the "missing from LLM response" raw-fallback path.
            return RefinementEchoStub.generateResponseJSON(fromUserPrompt: request.user)
        }
        if let builtinJSON = Self.builtinDefaults[key] {
            return builtinJSON
        }
        throw LLMClientError.missingStructuredOutput(raw: "no stub registered for stubKey=\"\(key)\"")
    }

    /// Mirrors `LLMClient.decodeResult`'s `.convertFromSnakeCase` decoding of `structured_output` so
    /// stub fixtures written in the same snake_case shape the real CLI emits (and the JSON Schema
    /// declares) decode into camelCase `T`s (e.g. `SummaryPatch`, `RefinementResponse`) identically.
    private static func decode<T: Decodable & Sendable>(_ rawJSON: String) throws -> LLMResult<T> {
        guard let data = rawJSON.data(using: .utf8) else {
            throw LLMClientError.invalidJSON(raw: rawJSON)
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let value = try decoder.decode(T.self, from: data)
            return LLMResult(value: value, usage: .zero)
        } catch {
            throw LLMClientError.decodeFailed(underlying: String(describing: error))
        }
    }

    private static func loadOverrides(path: String?) -> [String: String] {
        guard let path, !path.isEmpty else {
            return [:]
        }
        let expandedPath = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expandedPath) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

// MARK: - RefinementEchoStub

/// Generates the builtin dynamic response for the `"refinement"` stub key (`LLMStubProvider`,
/// `docs/design/03-refinement-batch.md` section 9, `docs/design/12-llm-client.md` section 5).
///
/// Parses the segment ids/raw texts out of the request's user prompt -- specifically only the
/// 【今回整形する対象】 block built by `RefinementPromptBuilder.buildUserPrompt(...)`, never the
/// preceding 【直前の文脈（整形済み）】 context block -- and echoes each target segment back as
/// `"[stub] " + rawText`, so the stub exercises `RefinementValidator`'s SUCCESS path deterministically
/// end to end (append to `refined.jsonl`, event emission, non-raw-fallback UI display).
///
/// DROP marker: a segment whose raw text contains the filler token "えーと", or whose trimmed raw text
/// is empty, echoes back `refined_text: ""` instead, exercising the intentional-drop path
/// (kikimi.md 7 章's "フィラー・相槌・言い直しの断片のみで...refined_text を空文字にする").
///
/// Deterministic by construction: pure string parsing, no randomness, no `Date()`.
enum RefinementEchoStub {
    /// Marks the start of `RefinementPromptBuilder.buildUserPrompt(...)`'s target-segment block. Text
    /// before this header (the 【直前の文脈（整形済み）】 block) is never parsed.
    private static let targetSectionHeader = "【今回整形する対象】"

    /// Filler token that marks a segment as meaningless-and-droppable, matching kikimi.md 7 章's
    /// filler-removal example list ("えーと」「あの」など). Only this one token is checked (not
    /// "あの") per this stub's spec -- it only needs *a* deterministic drop trigger for tests, not to
    /// reproduce the real Haiku prompt's full filler judgment.
    private static let dropToken = "えーと"

    static func generateResponseJSON(fromUserPrompt userPrompt: String) -> String {
        let items = targetSegments(in: userPrompt).map { segment in
            Item(id: segment.id, refinedText: echoedText(forRawText: segment.text), joinsNext: joinsNext(forRawText: segment.text))
        }
        // Snake-case encoding so the JSON survives `LLMStubProvider.decode(_:)`'s
        // `.convertFromSnakeCase` decode unchanged (mirrors `RefinementResponse.Item`'s wire shape,
        // `docs/design/12-llm-client.md` section 6.2).
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard
            let data = try? encoder.encode(Response(segments: items)),
            let json = String(data: data, encoding: .utf8)
        else {
            // Unreachable in practice (Item/Response are plain String-only Encodables), but falls
            // back to the old empty-segments shape rather than crashing the stub path.
            return "{\"segments\":[]}"
        }
        return json
    }

    /// `"[stub] " + rawText`, or `""` when `rawText` is the DROP marker (see this type's doc comment).
    private static func echoedText(forRawText rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !rawText.contains(dropToken) else {
            return ""
        }
        return "[stub] " + rawText
    }

    /// Sentence-final punctuation marks (`docs/design/03-refinement-batch.md` §15.2.7).
    private static let sentenceFinalPunctuation: Set<Character> = ["。", "？", "！", "?", "!"]

    /// §15.2.7: `rawText` not ending with one of `sentenceFinalPunctuation` is treated as
    /// unnaturally cut off, so the stub hints `joins_next: true`; text that already ends with one
    /// hints `false`. Applied uniformly (including to a DROP-marker segment, per the design note on
    /// "bookkeeping consistency") -- no trimming, mirroring `TranscriptSegment.text`'s own "no
    /// trailing newline" contract, so an empty `rawText` (no last character at all) also reads as
    /// "does not end with punctuation" -> `true`. Deterministic by construction: pure string check,
    /// no randomness, no `Date()`.
    private static func joinsNext(forRawText rawText: String) -> Bool {
        guard let lastCharacter = rawText.last else { return true }
        return !sentenceFinalPunctuation.contains(lastCharacter)
    }

    /// Extracts every `(id, text)` pair from the 【今回整形する対象】 block only.
    private static func targetSegments(in userPrompt: String) -> [(id: String, text: String)] {
        guard let headerRange = userPrompt.range(of: targetSectionHeader) else {
            return []
        }
        let block = userPrompt[headerRange.upperBound...]
        return block
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseLine(String($0)) }
    }

    /// Parses one `"\(id) (\(speaker)): \(text)"` line
    /// (`RefinementPromptBuilder.formatLine(id:speaker:text:)`'s exact format). Returns `nil` for
    /// lines that don't match (defensive; every line this stub actually receives is generated by
    /// `formatLine`, so this should never trigger in practice).
    private static func parseLine(_ line: String) -> (id: String, text: String)? {
        guard let openParenRange = line.range(of: " (") else {
            return nil
        }
        let id = String(line[line.startIndex..<openParenRange.lowerBound])
        let afterOpenParen = line[openParenRange.upperBound...]
        guard let closingDelimiterRange = afterOpenParen.range(of: "): ") else {
            return nil
        }
        let speaker = String(afterOpenParen[afterOpenParen.startIndex..<closingDelimiterRange.lowerBound])
        guard !id.isEmpty, AudioSourceKind(rawValue: speaker) != nil else {
            return nil
        }
        return (id: id, text: String(afterOpenParen[closingDelimiterRange.upperBound...]))
    }

    /// Encoded with `.convertToSnakeCase` (see `generateResponseJSON`) so `refinedText`/`joinsNext`
    /// serialize as `refined_text`/`joins_next` without a 2-level-nested `CodingKeys` (SwiftLint
    /// `nesting`).
    private struct Item: Encodable {
        var id: String
        var refinedText: String
        var joinsNext: Bool
    }

    private struct Response: Encodable {
        var segments: [Item]
    }
}
