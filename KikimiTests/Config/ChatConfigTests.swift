import Foundation
import Testing
import Yams

@testable import Kikimi

/// Layer 1 coverage for `ChatConfig` (`docs/design/38-session-chat.md` §6): defensive decoding of a
/// partial or absent `chat:` section, and the positive-value guard on the three numeric fields.
@Suite("ChatConfig")
struct ChatConfigTests {
    private func decodeConfig(_ yaml: String) throws -> KikimiConfigData {
        try YAMLDecoder().decode(KikimiConfigData.self, from: yaml)
    }

    @Test("a config.yaml with no chat: section falls back to the documented defaults")
    func absentSectionUsesDefaults() throws {
        let config = try decodeConfig("diarization:\n  enabled: true\n")

        #expect(config.chat == .default)
        #expect(config.chat.model == "claude-haiku-4-5-20251001")
        #expect(config.chat.maxContextChars == 120_000)
        #expect(config.chat.historyTurns == 6)
        #expect(config.chat.timeoutSeconds == 180)
    }

    @Test("a partial chat: section fills only the missing fields from the defaults")
    func partialSectionFillsMissingFields() throws {
        let config = try decodeConfig("""
        chat:
          model: claude-sonnet-5
        """)

        #expect(config.chat.model == "claude-sonnet-5")
        #expect(config.chat.maxContextChars == ChatConfig.default.maxContextChars)
        #expect(config.chat.historyTurns == ChatConfig.default.historyTurns)
    }

    @Test("every field round-trips when all are present")
    func fullSectionDecodes() throws {
        let config = try decodeConfig("""
        chat:
          model: gpt-5-mini
          max_context_chars: 60000
          history_turns: 4
          timeout_seconds: 90
        """)

        #expect(config.chat == ChatConfig(model: "gpt-5-mini", maxContextChars: 60_000, historyTurns: 4, timeoutSeconds: 90))
    }

    @Test("non-positive numeric values fall back to their defaults rather than disabling the feature")
    func nonPositiveValuesFallBack() throws {
        // `history_turns: 0` would make every question context-free and `timeout_seconds: 0` would
        // fail every call instantly -- both look like the feature is broken rather than misconfigured.
        let config = try decodeConfig("""
        chat:
          max_context_chars: 0
          history_turns: -2
          timeout_seconds: 0
        """)

        #expect(config.chat.maxContextChars == ChatConfig.default.maxContextChars)
        #expect(config.chat.historyTurns == ChatConfig.default.historyTurns)
        #expect(config.chat.timeoutSeconds == ChatConfig.default.timeoutSeconds)
    }
}
