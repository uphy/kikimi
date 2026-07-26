import Foundation

// MARK: - LLMBackend

/// One provider-specific completion call (`docs/design/14-llm-provider.md` section 2). `LLMClient`
/// owns the seam consumers depend on (`LLMCompleting`) and the single, shared `.convertFromSnakeCase`
/// decode of `structuredJSON` into the caller's `T`; a `LLMBackend` only has to produce the raw
/// schema-conformant JSON plus usage for one provider's wire format (`ClaudeCLIBackend` for the
/// `claude` CLI subprocess, `OpenAIChatBackend` for OpenAI-compatible HTTP chat completions).
protocol LLMBackend: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMBackendResponse
}

// MARK: - LLMBackendResponse

/// A backend's raw result: the schema-conformant structured output as undecoded `Data`, plus the
/// usage/cost the provider reported. `LLMClient` decodes `structuredJSON` into `T` with
/// `.convertFromSnakeCase` (`docs/design/12-llm-client.md` section 6.2's key-strategy note) -- kept
/// out of `LLMBackend` itself so every backend shares exactly one decode implementation.
struct LLMBackendResponse: Sendable {
    var structuredJSON: Data
    var usage: LLMUsage
    /// The model that actually answered this call, when the backend can tell -- e.g.
    /// `OpenAIChatBackend` reads the response body's `model` field (`docs/design/16-llm-usage-stats.md`
    /// section 2), which is the only reliable source for an Azure "legacy" deployment URL (the request
    /// body's `model` is ignored server-side there; the deployment name in the URL picks the model).
    /// `nil` when the backend has no such signal (`ClaudeCLIBackend`'s envelope carries none) -- the
    /// caller then falls back to `LLMRequest.model`, matching the pre-existing behavior.
    var respondedModel: String?
}
