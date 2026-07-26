import Foundation
import Testing
import Yams

@testable import Kikimi

/// Layer 1 coverage for `DictationHistoryConfig`'s decode behavior
/// (`docs/design/29-dictation-history.md` §7.1, DH1/DH7): missing keys fall back to `.default`,
/// invalid `max_entries` (< 1, or not decodable as an `Int` at all) falls back to
/// `.default.maxEntries` with a warning rather than being clamped, and valid values decode as-is.
@Suite("DictationHistoryConfig")
struct DictationConfigTests {
    private func decodeDictationConfig(_ yaml: String) throws -> DictationConfig {
        try YAMLDecoder().decode(DictationConfig.self, from: yaml)
    }

    // MARK: - Missing

    @Test("a dictation: section without a history: key falls back to DictationHistoryConfig.default")
    func missingHistoryKeyFallsBackToDefault() throws {
        let yaml = """
        enabled: true
        """
        let dictation = try decodeDictationConfig(yaml)
        #expect(dictation.history == .default)
        #expect(dictation.history.enabled == true)
        #expect(dictation.history.maxEntries == 100)
    }

    // MARK: - two_pass_decode (design 31 TP9)

    @Test("a missing two_pass_decode key defaults to true (opt-out, not opt-in)")
    func missingTwoPassDecodeDefaultsToTrue() throws {
        let yaml = """
        enabled: true
        """
        let dictation = try decodeDictationConfig(yaml)
        #expect(dictation.twoPassDecode == true)
    }

    @Test("two_pass_decode: false decodes as-is")
    func explicitTwoPassDecodeFalseDecodes() throws {
        let yaml = """
        enabled: true
        two_pass_decode: false
        """
        let dictation = try decodeDictationConfig(yaml)
        #expect(dictation.twoPassDecode == false)
    }

    @Test("a history: section with only enabled fills max_entries from DictationHistoryConfig.default")
    func partialHistorySectionFillsMissingFieldsFromDefault() throws {
        let yaml = """
        history:
          enabled: false
        """
        let dictation = try decodeDictationConfig(yaml)
        #expect(dictation.history.enabled == false, "the field the user did write must still be honored")
        #expect(dictation.history.maxEntries == DictationHistoryConfig.default.maxEntries)
    }

    // MARK: - Invalid

    @Test("history.max_entries: 0 is rejected (must be >= 1) and falls back to the default")
    func zeroMaxEntriesFallsBackToDefault() throws {
        let yaml = """
        history:
          max_entries: 0
        """
        let dictation = try decodeDictationConfig(yaml)
        #expect(dictation.history.maxEntries == DictationHistoryConfig.default.maxEntries)
    }

    @Test("a negative history.max_entries falls back to the default")
    func negativeMaxEntriesFallsBackToDefault() throws {
        let yaml = """
        history:
          max_entries: -1
        """
        let dictation = try decodeDictationConfig(yaml)
        #expect(dictation.history.maxEntries == DictationHistoryConfig.default.maxEntries)
    }

    @Test("a non-numeric history.max_entries falls back to the default rather than throwing")
    func nonNumericMaxEntriesFallsBackToDefault() throws {
        let yaml = """
        history:
          max_entries: "many"
        """
        let dictation = try decodeDictationConfig(yaml)
        #expect(dictation.history.maxEntries == DictationHistoryConfig.default.maxEntries)
    }

    // MARK: - Valid

    @Test("valid history values decode as-is")
    func validHistoryValuesDecode() throws {
        let yaml = """
        history:
          enabled: false
          max_entries: 50
        """
        let dictation = try decodeDictationConfig(yaml)
        #expect(dictation.history == DictationHistoryConfig(enabled: false, maxEntries: 50))
    }

    @Test("history.max_entries: 1 (the minimum valid value) decodes as-is, not clamped or rejected")
    func minimumValidMaxEntriesDecodes() throws {
        let yaml = """
        history:
          max_entries: 1
        """
        let dictation = try decodeDictationConfig(yaml)
        #expect(dictation.history.maxEntries == 1)
    }

    @Test("an unusually large history.max_entries decodes as-is: DH7 defines only a lower bound (>= 1), never an upper one")
    func largeMaxEntriesDecodesWithoutAnUpperBound() throws {
        let yaml = """
        history:
          max_entries: 100000
        """
        let dictation = try decodeDictationConfig(yaml)
        #expect(dictation.history.maxEntries == 100_000)
    }

    @Test("decodes design section 7.1's sample config.yaml history section")
    func decodesDesignSampleHistoryYAML() throws {
        let yaml = """
        history:
          enabled: true
          max_entries: 100
        """
        let dictation = try decodeDictationConfig(yaml)
        #expect(dictation.history == .default)
    }
}
