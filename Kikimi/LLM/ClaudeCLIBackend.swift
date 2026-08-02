import Foundation
import OSLog

// MARK: - ClaudeCLIBackend

/// `LLMBackend` for the `claude` CLI subprocess (`docs/design/12-llm-client.md` section 2,
/// `docs/design/14-llm-provider.md` section 2: "`ClaudeCLIBackend`: 既存実装の移設"). Argument
/// building and response-envelope parsing are moved from `LLMClient` unchanged except that the final
/// `structured_output` → `T` decode is no longer done here -- this backend hands back the raw
/// `structuredJSON` `Data` and lets `LLMClient` own that single, shared `.convertFromSnakeCase` decode
/// (14-llm-provider.md section 2's "ロジックは移動のみで書き換えない").
struct ClaudeCLIBackend: LLMBackend {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "ClaudeCLIBackend")

    private let runner: LLMProcessRunner

    init(runner: LLMProcessRunner = ClaudeCLIProcessRunner()) {
        self.runner = runner
    }

    // MARK: - LLMBackend

    func complete(_ request: LLMRequest) async throws -> LLMBackendResponse {
        let arguments = Self.buildArguments(request: request)
        let stdout: String
        do {
            stdout = try await runner.run(arguments: arguments, stdin: Self.buildStdin(request: request), timeout: request.timeout)
        } catch let error as LLMClientError {
            logger.error("claude CLI call failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        do {
            return try Self.decodeEnvelope(from: stdout)
        } catch let error as LLMClientError {
            logger.error("claude CLI response could not be decoded: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Argument building (section 2.1)

    /// Builds the fixed-flag argument list every call uses (`docs/design/12-llm-client.md` section
    /// 2.1's verified invocation shape). `static` and pure so it is directly unit-testable without a
    /// runner (section 7).
    ///
    /// `request.params.effort` (`docs/design/44-llm-model-config.md` §5.3) appends `--effort <value>`
    /// at the very end when non-nil; `nil` (every call site before that module, and any call that
    /// resolves to a param-less `ModelRef`) leaves this argument list byte-for-byte identical to
    /// before `params` existed -- "検証済みの CLI 呼び出し形を壊さない" (14 章 §2).
    static func buildArguments(request: LLMRequest) -> [String] {
        var arguments = [
            "-p",
            "--system-prompt", request.system,
            "--tools",
            "--exclude-dynamic-system-prompt-sections",
            "--setting-sources", "",
            "--output-format", "json",
            "--json-schema", request.schema,
            "--model", request.model
        ]
        if let effort = request.params.effort {
            arguments += ["--effort", effort]
        }
        return arguments
    }

    // MARK: - stdin assembly (38-session-chat.md section 4.1)

    /// Folds `request.messages` (if any) and `request.user` into the single prompt the CLI accepts.
    ///
    /// `claude -p --output-format json` takes one prompt on stdin and has no multi-turn input form
    /// (`--input-format stream-json` exists but is only usable together with
    /// `--output-format stream-json`, which would mean rewriting the whole response parser), so the
    /// conversation is flattened into `Q:` / `A:` blocks here -- in the backend, where the workaround
    /// can be deleted the day the CLI does support turn arrays, without touching prompt construction
    /// (38-session-chat.md CH15).
    ///
    /// Order is preserved exactly as the prompt builder laid it out: prior turns oldest-first, then
    /// the latest question last (§4.2's "安定した大きい塊 → 伸びる部分 → 最新の質問").
    ///
    /// With `messages == nil` -- every consumer other than chat -- this returns `request.user`
    /// unchanged, so no existing call path sees a single byte of difference.
    static func buildStdin(request: LLMRequest) -> String {
        guard let messages = request.messages, !messages.isEmpty else {
            return request.user
        }
        let priorTurns = messages.map { "\(prefix(for: $0.role))\($0.text)" }
        // The latest question carries the same `Q:` prefix as the prior user turns; without it the
        // model reads it as a continuation of the preceding `A:` block.
        return (priorTurns + ["\(prefix(for: .user))\(request.user)"]).joined(separator: "\n\n")
    }

    private static func prefix(for role: LLMMessage.Role) -> String {
        switch role {
        case .user: return "Q: "
        case .assistant: return "A: "
        }
    }

    // MARK: - Response parsing (section 6.2)

    /// Parses one `claude -p --output-format json --json-schema ...` invocation's captured stdout
    /// into a `LLMBackendResponse` (`structured_output` as raw `Data`, plus usage). `static` and pure
    /// so it is directly unit-testable without a runner (section 7).
    static func decodeEnvelope(from stdout: String) throws -> LLMBackendResponse {
        // CLI warnings can land on stdout ahead of the JSON result line (section 6.2), so only the
        // last non-empty line is treated as the response.
        guard let lastLine = lastNonEmptyLine(of: stdout) else {
            throw LLMClientError.invalidJSON(raw: stdout)
        }
        guard let lineData = lastLine.data(using: .utf8),
              let topLevel = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
        else {
            throw LLMClientError.invalidJSON(raw: lastLine)
        }

        // Envelope fields (`is_error`/`usage`/...) are decoded with a plain decoder + explicit
        // `CodingKeys`; `structured_output` is handed back as raw `Data` below (not decoded here at
        // all) so `LLMClient` can decode every backend's output into `T` the same way, with a
        // snake_case-converting decoder (matching how `SummaryState` is persisted via
        // `SessionJSONCoding`), rather than each `T` having to spell out explicit snake_case
        // `CodingKeys` (which would then conflict with `SessionJSONCoding`'s own
        // `.convertFromSnakeCase` when the same nested types round-trip through `summary.state.json`).
        let envelope = (try? JSONDecoder().decode(ClaudeCLIEnvelope.self, from: lineData)) ?? ClaudeCLIEnvelope()

        let usage = LLMUsage(
            inputTokens: envelope.usage?.inputTokens ?? 0,
            outputTokens: envelope.usage?.outputTokens ?? 0,
            cacheReadInputTokens: envelope.usage?.cacheReadInputTokens ?? 0,
            cacheCreationInputTokens: envelope.usage?.cacheCreationInputTokens ?? 0,
            totalCostUSD: envelope.totalCostUSD ?? 0
        )

        if let rawStructuredOutput = topLevel["structured_output"], !(rawStructuredOutput is NSNull) {
            let structuredData: Data
            do {
                structuredData = try JSONSerialization.data(withJSONObject: rawStructuredOutput)
            } catch {
                throw LLMClientError.decodeFailed(underlying: String(describing: error))
            }
            return LLMBackendResponse(structuredJSON: structuredData, usage: usage)
        }

        if envelope.isError == true, let authError = classifyAuthError(envelope: envelope) {
            throw authError
        }
        throw LLMClientError.missingStructuredOutput(raw: lastLine)
    }

    /// Section 4.1's C4: judged from machine-readable fields (`.subtype` / `.api_error_status`),
    /// never from message text, so CLI wording/locale changes can't silently break this. Best
    /// effort: the exact CLI `subtype` string for "not logged in" was not confirmed against a live
    /// unauthenticated CLI while implementing this (doing so would consume the user's Claude Max
    /// subscription quota, out of this task's scope; section 9's open question). Anything that
    /// doesn't clearly match one of these known signals falls through to `missingStructuredOutput`,
    /// which is the documented safe-by-default outcome.
    private static func classifyAuthError(envelope: ClaudeCLIEnvelope) -> LLMClientError? {
        if let status = envelope.apiErrorStatus, status == 401 || status == 403 {
            return .notAuthenticated
        }
        if let subtype = envelope.subtype, authSubtypes.contains(subtype) {
            return .notAuthenticated
        }
        return nil
    }

    private static let authSubtypes: Set<String> = [
        "error_auth", "error_unauthenticated", "error_not_logged_in", "error_login_required"
    ]

    private static func lastNonEmptyLine(of output: String) -> String? {
        var result: String?
        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                result = trimmed
            }
        }
        return result
    }
}

// MARK: - ClaudeCLIEnvelope (section 6.2 CLI response shape)

/// Decodes the CLI's one-line JSON response (`claude -p --output-format json --json-schema ...`).
/// Field names/shape per `docs/design/12-llm-client.md` section 2.1/4.1: `.structured_output` is the
/// schema-conformant payload (handed back as raw `Data` by `decodeEnvelope(from:)`), `.is_error` /
/// `.subtype` / `.api_error_status` drive error classification, `.usage` / `.total_cost_usd` become
/// `LLMUsage`.
///
/// Every field is optional -- a CLI response that's missing or renames one of these should surface
/// as `LLMClient`'s `.missingStructuredOutput` / `.decodeFailed`, not an opaque envelope-decode
/// crash unrelated to `structured_output` itself.
///
/// No `keyDecodingStrategy` is applied here (explicit `CodingKeys` cover every envelope field
/// instead). `structured_output` is intentionally *not* a field of this type -- it is decoded
/// separately in `decodeEnvelope(from:)`, so consumer `T`s can use plain camelCase Swift properties
/// without explicit snake_case `CodingKeys` (see that method's comment). Every field is optional so a
/// malformed/renamed envelope surfaces as `.missingStructuredOutput` rather than an opaque
/// envelope-decode failure.
private struct ClaudeCLIEnvelope: Decodable {
    var isError: Bool?
    var subtype: String?
    var apiErrorStatus: Int?
    var usage: ClaudeCLIUsage?
    var totalCostUSD: Double?

    init() {}

    enum CodingKeys: String, CodingKey {
        case isError = "is_error"
        case subtype
        case apiErrorStatus = "api_error_status"
        case usage
        case totalCostUSD = "total_cost_usd"
    }
}

private struct ClaudeCLIUsage: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}
