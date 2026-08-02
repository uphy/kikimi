import Foundation
import Testing

@testable import Kikimi

/// Coverage for `LLMRequest.init(system:user:messages:schema:resolved:functionDefaultSeconds:stubKey:)`
/// (`docs/design/44-llm-model-config.md` §5.1/§5.3): the convenience initializer callers use to build
/// a request straight from a `ModelResolver.resolve(...)` result, including the §3.3 "延長専用"
/// timeout computation.
@Suite("LLMRequest + ResolvedModel")
struct LLMRequestResolvedModelTests {
    @Test("copies provider/model/params from the resolved model unchanged")
    func copiesResolvedFieldsUnchanged() {
        let resolved = ResolvedModel(provider: "azure", model: "gpt-5.4-mini", params: LLMCallParams(effort: "high", timeoutSeconds: nil))
        let request = LLMRequest(system: "sys", user: "hello", schema: "{}", resolved: resolved)

        #expect(request.provider == "azure")
        #expect(request.model == "gpt-5.4-mini")
        #expect(request.params == LLMCallParams(effort: "high", timeoutSeconds: nil))
    }

    @Test("timeout falls back to functionDefaultSeconds when the resolved model has no timeout override")
    func timeoutFallsBackToFunctionDefault() {
        let resolved = ResolvedModel(provider: "claude", model: "claude-haiku-4-5-20251001")
        let request = LLMRequest(system: "sys", user: "hello", schema: "{}", resolved: resolved, functionDefaultSeconds: 90)

        #expect(request.timeout == .seconds(90))
    }

    @Test("timeout extends to the resolved model's timeout when it is longer than functionDefaultSeconds")
    func timeoutExtendsWhenModelDefinitionIsLonger() {
        let resolved = ResolvedModel(provider: "claude", model: "claude-sonnet-5", params: LLMCallParams(timeoutSeconds: 300))
        let request = LLMRequest(system: "sys", user: "hello", schema: "{}", resolved: resolved, functionDefaultSeconds: 60)

        #expect(request.timeout == .seconds(300))
    }

    @Test("timeout never shrinks below functionDefaultSeconds when the resolved model's timeout is shorter")
    func timeoutNeverShrinksBelowFunctionDefault() {
        let resolved = ResolvedModel(provider: "claude", model: "claude-sonnet-5", params: LLMCallParams(timeoutSeconds: 10))
        let request = LLMRequest(system: "sys", user: "hello", schema: "{}", resolved: resolved, functionDefaultSeconds: 60)

        #expect(request.timeout == .seconds(60))
    }
}
