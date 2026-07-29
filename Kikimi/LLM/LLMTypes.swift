import Foundation

// MARK: - LLMCompleting

/// The seam consumers depend on (`SummaryUpdater`, future refinement/watcher runners). Kept as a
/// narrow protocol -- not the concrete `LLMClient` -- so consumers can inject a hand-written fake in
/// unit tests without going through the CLI-output-decoding path at all. See
/// `docs/design/12-llm-client.md` section 4.
protocol LLMCompleting: Sendable {
    func complete<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T>

    /// Returns the backend's schema-conformant `structured_output` as raw, undecoded `Data` -- no
    /// `.convertFromSnakeCase` key transform, no `Decodable` type at all
    /// (`docs/design/05-watcher-runner.md` §5.1). For consumers whose schema is only known at
    /// runtime (`WatcherRunner`, whose Watcher `schema:` frontmatter is user-defined per
    /// `docs/design/05-watcher-runner.md` §2.2): decoding through `JSONDecoder`'s key-strategy would
    /// mangle a dynamic key like `source_seg_id` into `sourceSegId`, breaking the view template's
    /// variable lookup. Every other consumer (`SummaryUpdater`/`RefinementQueue`) has a fixed `T` and
    /// should keep using `complete(_:)`.
    func completeRaw(_ request: LLMRequest) async throws -> LLMResult<Data>
}

// MARK: - LLMRequest

/// One structured-output call. `schema` is a JSON Schema string the consumer holds as a constant;
/// its shape must match `T` (verified by a unit test that decodes a sample into `T`). See
/// `docs/design/12-llm-client.md` section 4.
struct LLMRequest: Sendable {
    /// Fixed system prompt, kept small (section 2.2's prompt-caching note: `--system-prompt`
    /// replaces Claude Code's own, and small system prompts are not `cache_creation`'d).
    var system: String
    /// Per-call prompt, passed on stdin (section 2.1). When `messages` is non-nil this is the
    /// *latest* turn only -- everything before it lives in `messages`.
    var user: String
    /// Prior conversation turns, oldest first, excluding the latest one (that is `user`).
    /// `nil` for every single-shot consumer (refinement / summary / title / watcher / dictation),
    /// which is why those call sites need no change at all
    /// (`docs/design/38-session-chat.md` §8.1(b)/CH15).
    ///
    /// Deliberately handed to the backend as a *structured* array rather than pre-flattened text:
    /// each backend decides how to carry it (`OpenAIChatBackend` sends the array as-is;
    /// `ClaudeCLIBackend` folds it into one stdin string because `claude -p --output-format json`
    /// takes a single prompt). Flattening in the prompt builder instead would have to be undone the
    /// day the CLI grows `--input-format stream-json` (§4.1).
    var messages: [LLMMessage]?
    /// Handed to `--json-schema` verbatim.
    var schema: String
    /// Resolved model id. The caller resolves this from `AppConfig`; `LLMClient` itself never reads
    /// config (section 8's interface contract).
    var model: String
    var timeout: Duration = .seconds(60)
    /// Stub-mode dispatch key (section 5). Ignored by `ClaudeCLIProcessRunner`; only
    /// `LLMStubProvider` reads it, and only when `KIKIMI_STUB_LLM=1`.
    var stubKey: String?
}

// MARK: - LLMMessage

/// One prior turn of a multi-turn conversation, carried in `LLMRequest.messages`
/// (`docs/design/38-session-chat.md` §4.1). Only the session-chat feature produces these; every
/// other consumer leaves `messages` nil.
///
/// There is no `system` role: the system prompt is `LLMRequest.system`, which every backend already
/// places correctly (`--system-prompt` for the CLI, `messages[0]` for OpenAI-compatible endpoints).
struct LLMMessage: Sendable, Equatable {
    enum Role: String, Sendable, Equatable {
        case user
        case assistant
    }

    var role: Role
    var text: String
}

// MARK: - LLMResult

/// `value` plus the usage/cost the CLI reported, so callers that want per-session cost accounting
/// (section 9, kikimi.md 15 章) get it without a later breaking signature change. Callers that don't
/// care just read `.value`.
struct LLMResult<T: Sendable>: Sendable {
    var value: T
    var usage: LLMUsage
    /// Forwarded from `LLMBackendResponse.respondedModel` (see that type's doc comment): the model
    /// that actually answered, when the backend can tell. `nil` for `ClaudeCLIBackend` and stub mode --
    /// callers that persist a "model" field (`UsageRecordingLLM`, `RefinementQueue`) fall back to
    /// `LLMRequest.model` in that case.
    var respondedModel: String?
}

// MARK: - LLMUsage

struct LLMUsage: Sendable, Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadInputTokens: Int
    var cacheCreationInputTokens: Int
    var totalCostUSD: Double

    /// The all-zero usage every stub-mode response reports (section 5: "`usage` はゼロ値の
    /// `LLMUsage` を返す").
    static let zero = LLMUsage(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadInputTokens: 0,
        cacheCreationInputTokens: 0,
        totalCostUSD: 0
    )
}

// MARK: - LLMClientError

/// Failure modes surfaced by `LLMClient.complete(_:)`. Every case is designed so the caller can
/// safely "skip this update and continue" (section 4.1; kikimi.md 8.5's backpressure /
/// refinement-failure-fallback philosophy) -- `LLMClient` never touches recording or session
/// persistence itself.
enum LLMClientError: Error, Equatable, Sendable {
    /// `claude` executable could not be resolved (section 3.1). Carries every path that was tried,
    /// for diagnostics in the startup-warning UI.
    case cliNotFound(searchedPaths: [String])
    /// The CLI's response indicates the OAuth session is missing/expired (section 4.1's C4: judged
    /// from machine-readable fields only, never message text).
    case notAuthenticated
    case processFailed(exitCode: Int32, stderr: String)
    case timedOut(Duration)
    /// CLI stdout's last non-empty line is not valid JSON at all.
    case invalidJSON(raw: String)
    /// The response JSON parsed, but has no usable `structured_output` (missing, or `is_error: true`
    /// without a more specific classification such as `.notAuthenticated`).
    case missingStructuredOutput(raw: String)
    /// `structured_output` was present but did not decode into the caller's `T`.
    case decodeFailed(underlying: String)
    /// `openai` provider: neither `llm.openai.api_key` nor the `llm.openai.api_key_env` environment
    /// variable resolved to a non-empty API key (`docs/design/14-llm-provider.md` section 3's "API
    /// キー解決順").
    case missingAPIKey
    /// `openai` provider: a non-2xx HTTP response that isn't 401/403 (those classify as
    /// `.notAuthenticated` instead; section 4.2). `body` is truncated to 1KB.
    case httpFailed(status: Int, body: String)
    /// `openai` provider: a `URLSession` transport-layer failure other than a timeout (which
    /// classifies as `.timedOut` instead; section 4.2).
    case networkFailed(description: String)
}

extension LLMClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cliNotFound(let searchedPaths):
            return "claude CLI not found (searched: \(searchedPaths.joined(separator: ", ")))"
        case .notAuthenticated:
            return "claude CLI is not authenticated (run `claude login`)"
        case .processFailed(let exitCode, let stderr):
            return "claude CLI exited with code \(exitCode): \(stderr)"
        case .timedOut(let timeout):
            return "claude CLI call timed out after \(timeout)"
        case .invalidJSON(let raw):
            return "claude CLI output was not valid JSON: \(raw)"
        case .missingStructuredOutput(let raw):
            return "claude CLI response had no structured_output: \(raw)"
        case .decodeFailed(let underlying):
            return "structured_output did not match the expected type: \(underlying)"
        case .missingAPIKey:
            return "no OpenAI-compatible API key resolved (set llm.openai.api_key or llm.openai.api_key_env)"
        case .httpFailed(let status, let body):
            return "OpenAI-compatible endpoint returned HTTP \(status): \(body)"
        case .networkFailed(let description):
            return "OpenAI-compatible endpoint request failed: \(description)"
        }
    }
}

// MARK: - LLMHealthCheckResult

/// Result of `LLMClient.healthCheck(model:)` (section 3's "起動時ヘルスチェック"). UI wiring
/// (warning banner, etc.) is a later component's job; this only exposes the primitive.
enum LLMHealthCheckResult: Sendable, Equatable {
    case available
    case unavailable(LLMClientError)
}
