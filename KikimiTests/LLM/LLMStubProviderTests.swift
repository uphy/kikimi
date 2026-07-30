import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `LLMStubProvider` in isolation from `LLMClient`
/// (`docs/design/12-llm-client.md` section 5).
@Suite("LLMStubProvider")
struct LLMStubProviderTests {
    private struct SamplePayload: Decodable, Sendable, Equatable {
        var title: String
        var count: Int
    }

    private func makeRequest(stubKey: String?) -> LLMRequest {
        LLMRequest(system: "s", user: "u", schema: "{}", model: "claude-haiku-4-5-20251001", stubKey: stubKey)
    }

    private func writeOverridesFile(_ overrides: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMStubProviderTests-\(UUID().uuidString).json")
        try JSONEncoder().encode(overrides).write(to: url)
        return url
    }

    @Test("isEnabled is false when KIKIMI_STUB_LLM is unset")
    func isEnabledFalseWhenUnset() {
        let provider = LLMStubProvider(environment: [:])
        #expect(!provider.isEnabled)
    }

    @Test("isEnabled is false for any value other than exactly \"1\"")
    func isEnabledFalseForNonOneValue() {
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "true"])
        #expect(!provider.isEnabled)
    }

    @Test("isEnabled is true when KIKIMI_STUB_LLM=1")
    func isEnabledTrueWhenSet() {
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1"])
        #expect(provider.isEnabled)
    }

    @Test("stubResult decodes the raw JSON registered under the request's stubKey")
    func stubResultDecodesRegisteredKey() throws {
        let file = try writeOverridesFile(["title-case": "{\"title\":\"stubbed\",\"count\":7}"])
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1", "KIKIMI_STUB_LLM_FILE": file.path])

        let result: LLMResult<SamplePayload> = try provider.stubResult(for: makeRequest(stubKey: "title-case"))

        #expect(result.value == SamplePayload(title: "stubbed", count: 7))
        #expect(result.usage == .zero)
    }

    @Test("stubResult throws missingStructuredOutput for an unregistered stubKey")
    func stubResultThrowsForUnregisteredKey() throws {
        let file = try writeOverridesFile(["known": "{\"title\":\"x\",\"count\":1}"])
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1", "KIKIMI_STUB_LLM_FILE": file.path])

        #expect(throws: LLMClientError.missingStructuredOutput(raw: "no stub registered for stubKey=\"unknown\"")) {
            let _: LLMResult<SamplePayload> = try provider.stubResult(for: makeRequest(stubKey: "unknown"))
        }
    }

    @Test("stubResult throws missingStructuredOutput when no KIKIMI_STUB_LLM_FILE is configured at all")
    func stubResultThrowsWithoutOverridesFile() throws {
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1"])
        #expect(throws: LLMClientError.self) {
            let _: LLMResult<SamplePayload> = try provider.stubResult(for: makeRequest(stubKey: "anything"))
        }
    }

    @Test("stubResult throws decodeFailed when the registered JSON does not match T")
    func stubResultThrowsDecodeFailedForMismatchedShape() throws {
        let file = try writeOverridesFile(["bad-shape": "{\"unexpected\":true}"])
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1", "KIKIMI_STUB_LLM_FILE": file.path])

        do {
            let _: LLMResult<SamplePayload> = try provider.stubResult(for: makeRequest(stubKey: "bad-shape"))
            Issue.record("expected decodeFailed to be thrown")
        } catch let error as LLMClientError {
            guard case .decodeFailed = error else {
                Issue.record("expected decodeFailed, got \(error)")
                return
            }
        }
    }

    @Test("a nonexistent KIKIMI_STUB_LLM_FILE path is tolerated (empty overrides, not a crash)")
    func nonexistentOverridesFileIsTolerated() {
        let provider = LLMStubProvider(environment: [
            "KIKIMI_STUB_LLM": "1",
            "KIKIMI_STUB_LLM_FILE": "/nonexistent/path/stubs.json"
        ])
        #expect(throws: LLMClientError.self) {
            let _: LLMResult<SamplePayload> = try provider.stubResult(for: makeRequest(stubKey: "anything"))
        }
    }

    // MARK: - "chat" builtin default (38-session-chat.md CH11b)

    private struct ChatAnswerPayload: Decodable, Sendable, Equatable {
        var answer: String
    }

    @Test("stubResult answers the \"chat\" stubKey from builtinDefaults with no override file")
    func stubResultUsesBuiltinDefaultForChat() throws {
        // Without this entry, every chat send under KIKIMI_STUB_LLM=1 (verify-smoke, kikimi-verify)
        // would throw missingStructuredOutput.
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1"])

        let result: LLMResult<ChatAnswerPayload> = try provider.stubResult(for: makeRequest(stubKey: "chat"))

        #expect(result.value.answer.hasPrefix("[stub]"))
        #expect(result.usage == .zero)
    }

    @Test("an override file entry for \"chat\" wins over the built-in default")
    func overrideFileWinsOverBuiltinDefaultForChat() throws {
        let file = try writeOverridesFile(["chat": "{\"answer\":\"overridden\"}"])
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1", "KIKIMI_STUB_LLM_FILE": file.path])

        let result: LLMResult<ChatAnswerPayload> = try provider.stubResult(for: makeRequest(stubKey: "chat"))

        #expect(result.value == ChatAnswerPayload(answer: "overridden"))
    }

    private struct RefinementResponse: Decodable, Sendable, Equatable {
        struct Item: Decodable, Sendable, Equatable {
            var id: String
            var refinedText: String
        }

        var segments: [Item]
    }

    /// `makeRequest(stubKey:)` above always passes `user: "u"`, which has no
    /// 【今回整形する対象】 header at all, so the builtin echo stub parses zero target segments and
    /// returns an empty `segments` array. `refinementUserPrompt(targets:)` below is used by the
    /// echo-specific tests that need a realistic `RefinementPromptBuilder`-shaped prompt.
    @Test("stubResult falls back to the built-in echo default (empty segments for a prompt with no target block) when no override file is configured")
    func stubResultUsesBuiltinDefaultForRefinement() throws {
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1"])

        let result: LLMResult<RefinementResponse> = try provider.stubResult(for: makeRequest(stubKey: "refinement"))

        #expect(result.value == RefinementResponse(segments: []))
        #expect(result.usage == .zero)
    }

    @Test("an override file entry for \"refinement\" wins over the built-in echo default")
    func overrideFileWinsOverBuiltinDefaultForRefinement() throws {
        let file = try writeOverridesFile([
            "refinement": "{\"segments\":[{\"id\":\"seg_00001\",\"refined_text\":\"整形済み\"}]}"
        ])
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1", "KIKIMI_STUB_LLM_FILE": file.path])

        let result: LLMResult<RefinementResponse> = try provider.stubResult(for: makeRequest(stubKey: "refinement"))

        #expect(result.value == RefinementResponse(segments: [.init(id: "seg_00001", refinedText: "整形済み")]))
    }

    /// An override file entry can still restore the *old* fixed `{"segments": []}` shape verbatim,
    /// for any test that specifically wants the "every id missing from LLM response" raw-fallback
    /// path regardless of what the request's user prompt actually contains
    /// (docs/design/03-refinement-batch.md section 9's "結果: バッチ全件が...raw フォールバック表示").
    @Test("an override file can restore the old fixed empty-segments refinement response, ignoring the request's user prompt")
    func overrideFileCanRestoreOldEmptySegmentsBehavior() throws {
        let file = try writeOverridesFile(["refinement": "{\"segments\":[]}"])
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1", "KIKIMI_STUB_LLM_FILE": file.path])
        let request = LLMRequest(
            system: "s",
            user: refinementUserPrompt(targets: [(id: "seg_00042", speaker: "mic", text: "そうですね")]),
            schema: "{}",
            model: "claude-haiku-4-5-20251001",
            stubKey: "refinement"
        )

        let result: LLMResult<RefinementResponse> = try provider.stubResult(for: request)

        #expect(result.value == RefinementResponse(segments: []))
    }

    // MARK: - Refinement echo stub (docs/design/03-refinement-batch.md section 9)

    /// Builds a user prompt in exactly `RefinementPromptBuilder.buildUserPrompt(...)`'s shape, so
    /// these tests exercise the same parsing the real `RefinementQueue` call site produces.
    private func refinementUserPrompt(context: [(id: String, speaker: String, text: String)] = [], targets: [(id: String, speaker: String, text: String)]) -> String {
        let contextBlock = context.map { "\($0.id) (\($0.speaker)): \($0.text)" }.joined(separator: "\n")
        let targetBlock = targets.map { "\($0.id) (\($0.speaker)): \($0.text)" }.joined(separator: "\n")
        return "【直前の文脈（整形済み）】\n\(contextBlock)\n\n【今回整形する対象】\n\(targetBlock)"
    }

    @Test("refinement echo stub echoes multiple target segments as \"[stub] \" + rawText, in request order")
    func refinementEchoStubEchoesMultipleIds() throws {
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1"])
        let request = LLMRequest(
            system: "s",
            user: refinementUserPrompt(targets: [
                (id: "seg_00042", speaker: "mic", text: "そうですね、次のスプリントで対応します"),
                (id: "seg_00043", speaker: "system", text: "了解しました")
            ]),
            schema: "{}",
            model: "claude-haiku-4-5-20251001",
            stubKey: "refinement"
        )

        let result: LLMResult<RefinementResponse> = try provider.stubResult(for: request)

        #expect(result.value == RefinementResponse(segments: [
            .init(id: "seg_00042", refinedText: "[stub] そうですね、次のスプリントで対応します"),
            .init(id: "seg_00043", refinedText: "[stub] 了解しました")
        ]))
    }

    @Test("refinement echo stub never echoes ids from the 【直前の文脈（整形済み）】 context block")
    func refinementEchoStubIgnoresContextBlock() throws {
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1"])
        let request = LLMRequest(
            system: "s",
            user: refinementUserPrompt(
                context: [(id: "seg_00039", speaker: "mic", text: "文脈セグメント")],
                targets: [(id: "seg_00042", speaker: "mic", text: "対象セグメント")]
            ),
            schema: "{}",
            model: "claude-haiku-4-5-20251001",
            stubKey: "refinement"
        )

        let result: LLMResult<RefinementResponse> = try provider.stubResult(for: request)

        #expect(result.value.segments.map(\.id) == ["seg_00042"])
        #expect(!result.value.segments.contains { $0.id == "seg_00039" })
    }

    @Test("refinement echo stub returns an empty refined_text (DROP marker) for a segment whose raw text contains \"えーと\"")
    func refinementEchoStubDropsFillerToken() throws {
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1"])
        let request = LLMRequest(
            system: "s",
            user: refinementUserPrompt(targets: [(id: "seg_00050", speaker: "mic", text: "えーと、あの")]),
            schema: "{}",
            model: "claude-haiku-4-5-20251001",
            stubKey: "refinement"
        )

        let result: LLMResult<RefinementResponse> = try provider.stubResult(for: request)

        #expect(result.value == RefinementResponse(segments: [.init(id: "seg_00050", refinedText: "")]))
    }

    @Test("refinement echo stub returns an empty refined_text (DROP marker) for a segment whose raw text is blank")
    func refinementEchoStubDropsBlankText() throws {
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1"])
        let request = LLMRequest(
            system: "s",
            user: refinementUserPrompt(targets: [(id: "seg_00051", speaker: "system", text: "   ")]),
            schema: "{}",
            model: "claude-haiku-4-5-20251001",
            stubKey: "refinement"
        )

        let result: LLMResult<RefinementResponse> = try provider.stubResult(for: request)

        #expect(result.value == RefinementResponse(segments: [.init(id: "seg_00051", refinedText: "")]))
    }

    @Test("refinement echo stub hints joins_next=true when raw text lacks sentence-final punctuation, false when it has one (§15.2.7)")
    func refinementEchoStubJoinsNextRule() throws {
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1"])
        let request = LLMRequest(
            system: "s",
            user: refinementUserPrompt(targets: [
                (id: "seg_00060", speaker: "mic", text: "そうですね、次のスプリントで"),
                (id: "seg_00061", speaker: "mic", text: "対応します。"),
                (id: "seg_00062", speaker: "mic", text: "")
            ]),
            schema: "{}",
            model: "claude-haiku-4-5-20251001",
            stubKey: "refinement"
        )

        // Decodes into the *real* `Kikimi.RefinementResponse` (not this file's local decode-only
        // mirror, which has no `joinsNext` field) so `joins_next` itself is asserted.
        let result: LLMResult<Kikimi.RefinementResponse> = try provider.stubResult(for: request)

        #expect(result.value.segments.first { $0.id == "seg_00060" }?.joinsNext == true, "text not ending in 。？！?! hints joins_next=true")
        #expect(result.value.segments.first { $0.id == "seg_00061" }?.joinsNext == false, "text ending in 。 hints joins_next=false")
        #expect(result.value.segments.first { $0.id == "seg_00062" }?.joinsNext == true, "no trailing character at all also hints joins_next=true")
    }

    @Test("stubResult still throws missingStructuredOutput for a key registered in neither map")
    func stubResultThrowsForKeyInNeitherMap() {
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1"])

        #expect(throws: LLMClientError.missingStructuredOutput(raw: "no stub registered for stubKey=\"unregistered\"")) {
            let _: LLMResult<SamplePayload> = try provider.stubResult(for: makeRequest(stubKey: "unregistered"))
        }
    }

    // MARK: - stubRawResult (`docs/design/05-watcher-runner.md` §5.1)

    @Test("stubRawResult returns the registered raw JSON undecoded, with snake_case keys intact")
    func stubRawResultReturnsRegisteredKeyUndecoded() throws {
        let file = try writeOverridesFile(["watcher_pre-check": "{\"source_seg_id\":\"seg_00001\"}"])
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1", "KIKIMI_STUB_LLM_FILE": file.path])

        let result = try provider.stubRawResult(for: makeRequest(stubKey: "watcher_pre-check"))

        #expect(String(data: result.value, encoding: .utf8) == "{\"source_seg_id\":\"seg_00001\"}")
        #expect(result.usage == .zero)
    }

    @Test("stubRawResult throws missingStructuredOutput for an unregistered stubKey")
    func stubRawResultThrowsForUnregisteredKey() {
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1"])

        #expect(throws: LLMClientError.missingStructuredOutput(raw: "no stub registered for stubKey=\"unregistered\"")) {
            _ = try provider.stubRawResult(for: makeRequest(stubKey: "unregistered"))
        }
    }

    @Test("stubRawResult shares the refinement echo stub's dynamic response with stubResult")
    func stubRawResultSharesRefinementEchoStub() throws {
        let provider = LLMStubProvider(environment: ["KIKIMI_STUB_LLM": "1"])
        let request = LLMRequest(
            system: "s",
            user: refinementUserPrompt(targets: [(id: "seg_00042", speaker: "mic", text: "対象セグメント")]),
            schema: "{}",
            model: "claude-haiku-4-5-20251001",
            stubKey: "refinement"
        )

        let result = try provider.stubRawResult(for: request)

        let decoded: LLMResult<RefinementResponse> = try provider.stubResult(for: request)
        #expect(String(data: result.value, encoding: .utf8)?.contains("seg_00042") == true)
        #expect(decoded.value.segments.map(\.id) == ["seg_00042"])
    }
}
