import Foundation
import Testing

@testable import Kikimi

// MARK: - DictationHistoryEntry

@Suite("DictationHistoryEntry")
struct DictationHistoryEntryTests {
    /// `docs/design/29-dictation-history.md` section 3.2 sample JSON.
    static let sampleJSON = """
    {
      "recorded_at": "2026-07-10T09:15:32Z",
      "duration_ms": 4210,
      "target_bundle_id": "com.google.Chrome",
      "raw_text": "きき身の履歴機能について",
      "refined_text": "Kikimiの履歴機能について",
      "final_text": "Kikimiの履歴機能について",
      "refine_outcome": "success",
      "refine_error": null,
      "insert_outcome": "inserted",
      "llm_usage": {
        "timestamp": "2026-07-10T09:15:33Z",
        "purpose": "dictation",
        "model": "claude-haiku-4-5-20251001",
        "input_tokens": 412,
        "output_tokens": 18,
        "cache_read_input_tokens": 0,
        "cache_creation_input_tokens": 0,
        "reported_cost_usd": null
      }
    }
    """

    @Test("decodes design 29 section 3.2's sample JSON, converting snake_case keys throughout")
    func decodesSampleJSON() throws {
        let decoder = SessionJSONCoding.makeDecoder()
        let entry = try decoder.decode(DictationHistoryEntry.self, from: Data(Self.sampleJSON.utf8))

        #expect(entry.durationMs == 4_210)
        #expect(entry.targetBundleId == "com.google.Chrome")
        #expect(entry.rawText == "きき身の履歴機能について")
        #expect(entry.refinedText == "Kikimiの履歴機能について")
        #expect(entry.finalText == "Kikimiの履歴機能について")
        #expect(entry.refineOutcome == .success)
        #expect(entry.refineError == nil)
        #expect(entry.insertOutcome == .inserted)

        let usage = try #require(entry.llmUsage)
        #expect(usage.purpose == "dictation")
        #expect(usage.model == "claude-haiku-4-5-20251001")
        #expect(usage.inputTokens == 412)
        #expect(usage.outputTokens == 18)
        #expect(usage.cacheReadInputTokens == 0)
        #expect(usage.cacheCreationInputTokens == 0)
        #expect(usage.reportedCostUSD == nil)

        var expectedComponents = DateComponents()
        expectedComponents.year = 2_026
        expectedComponents.month = 7
        expectedComponents.day = 10
        expectedComponents.hour = 9
        expectedComponents.minute = 15
        expectedComponents.second = 32
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(entry.recordedAt == utcCalendar.date(from: expectedComponents)!)
    }

    @Test("decodes a pre-design-31 entry.json with no raw_source/streaming_text keys as nil (back-compat)")
    func decodesPreExistingEntryWithoutTwoPassFields() throws {
        let decoder = SessionJSONCoding.makeDecoder()
        let entry = try decoder.decode(DictationHistoryEntry.self, from: Data(Self.sampleJSON.utf8))

        #expect(entry.rawSource == nil)
        #expect(entry.streamingText == nil)
    }

    @Test("round-trips raw_source/streaming_text through snake_case keys (design 31 TP7)")
    func roundTripsTwoPassFields() throws {
        let entry = DictationHistoryEntry(
            recordedAt: Date(timeIntervalSince1970: 1_760_000_000),
            durationMs: 8_385,
            targetBundleId: "com.example.editor",
            rawText: "ディクテーション履歴のテスト中、きょうはレグ環境の構築を行います。",
            rawSource: .batch,
            streamingText: "ディクテーション履歴のテスト中はレグ環境の構築を行います",
            refinedText: nil,
            finalText: "ディクテーション履歴のテスト中、きょうはレグ環境の構築を行います。",
            refineOutcome: .disabled,
            refineError: nil,
            insertOutcome: .inserted,
            llmUsage: nil
        )

        let data = try SessionJSONCoding.makeEncoder().encode(entry)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""raw_source":"batch""#))
        #expect(json.contains(#""streaming_text""#))

        let decoded = try SessionJSONCoding.makeDecoder().decode(DictationHistoryEntry.self, from: data)
        #expect(decoded == entry)
    }

    @Test("round-trips a streaming-confirmed entry (raw_source streaming, no diagnostic text)")
    func roundTripsStreamingSourceWithoutDiagnostic() throws {
        let entry = DictationHistoryEntry(
            recordedAt: Date(timeIntervalSince1970: 1_760_000_000),
            durationMs: 1_200,
            targetBundleId: nil,
            rawText: "ストリーミングで確定した発話",
            rawSource: .streaming,
            streamingText: nil,
            refinedText: nil,
            finalText: "ストリーミングで確定した発話",
            refineOutcome: .disabled,
            refineError: nil,
            insertOutcome: .inserted,
            llmUsage: nil
        )

        let data = try SessionJSONCoding.makeEncoder().encode(entry)
        let decoded = try SessionJSONCoding.makeDecoder().decode(DictationHistoryEntry.self, from: data)
        #expect(decoded.rawSource == .streaming)
        #expect(decoded.streamingText == nil)
        #expect(decoded == entry)
    }

    @Test("round-trips a success entry, including the nested llm_usage (design 29's DH5)")
    func roundTripsSuccessWithUsage() throws {
        let original = DictationHistoryEntry(
            recordedAt: Date(timeIntervalSince1970: 1_751_000_000),
            durationMs: 4_210,
            targetBundleId: "com.google.Chrome",
            rawText: "きき身の履歴機能について",
            refinedText: "Kikimiの履歴機能について",
            finalText: "Kikimiの履歴機能について",
            refineOutcome: .success,
            refineError: nil,
            insertOutcome: .inserted,
            llmUsage: LLMUsageRecord(
                timestamp: Date(timeIntervalSince1970: 1_751_000_001),
                purpose: "dictation",
                model: "claude-haiku-4-5-20251001",
                inputTokens: 412,
                outputTokens: 18,
                cacheReadInputTokens: 0,
                cacheCreationInputTokens: 0,
                reportedCostUSD: nil
            )
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(DictationHistoryEntry.self, from: data)

        #expect(decoded == original)
        #expect(decoded.llmUsage == original.llmUsage)
    }

    @Test("round-trips a fallback entry with no target app, no refined text, and no usage")
    func roundTripsFallbackWithoutUsage() throws {
        let original = DictationHistoryEntry(
            recordedAt: Date(timeIntervalSince1970: 1_751_000_100),
            durationMs: 1_800,
            targetBundleId: nil,
            rawText: "テストです",
            refinedText: nil,
            finalText: "テストです",
            refineOutcome: .fallback,
            refineError: "missingAPIKey",
            insertOutcome: .abortedAndStashed,
            llmUsage: nil
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(DictationHistoryEntry.self, from: data)

        #expect(decoded == original)
        #expect(decoded.refinedText == nil)
        #expect(decoded.llmUsage == nil)
    }

    @Test("round-trips the empty-refinement fallback: fallback outcome, but usage is still preserved (section 3.2's invariant note)")
    func roundTripsEmptyRefinementFallbackWithUsagePreserved() throws {
        let original = DictationHistoryEntry(
            recordedAt: Date(timeIntervalSince1970: 1_751_000_200),
            durationMs: 900,
            targetBundleId: "com.apple.Terminal",
            rawText: "うーん",
            refinedText: nil,
            finalText: "うーん",
            refineOutcome: .fallback,
            refineError: "empty refinement",
            insertOutcome: .inserted,
            llmUsage: LLMUsageRecord(
                timestamp: Date(timeIntervalSince1970: 1_751_000_201),
                purpose: "dictation",
                model: "claude-haiku-4-5-20251001",
                inputTokens: 50,
                outputTokens: 1,
                cacheReadInputTokens: 0,
                cacheCreationInputTokens: 0,
                reportedCostUSD: nil
            )
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(DictationHistoryEntry.self, from: data)

        #expect(decoded == original)
        #expect(decoded.refineOutcome == .fallback)
        #expect(decoded.refineError == "empty refinement")
        #expect(decoded.llmUsage != nil)
        // The invariant this case exists to satisfy: `success` outcomes always have
        // `finalText == refinedText`, but this entry is *not* `.success` precisely because the
        // refinement text was empty, so `finalText` legitimately differs from (nil) `refinedText`.
        #expect(decoded.finalText == decoded.rawText)
    }

    @Test("round-trips a disabled-refinement entry (refined_text and llm_usage both nil, DH12)")
    func roundTripsDisabledRefinement() throws {
        let original = DictationHistoryEntry(
            recordedAt: Date(timeIntervalSince1970: 1_751_000_300),
            durationMs: 2_000,
            targetBundleId: "com.apple.Notes",
            rawText: "そのまま挿入されるテキスト",
            refinedText: nil,
            finalText: "そのまま挿入されるテキスト",
            refineOutcome: .disabled,
            refineError: nil,
            insertOutcome: .inserted,
            llmUsage: nil
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(DictationHistoryEntry.self, from: data)

        #expect(decoded == original)
    }

    @Test("decodes a pre-existing entry.json with no mic_device_name/mic_device_uid keys as nil (back-compat)")
    func decodesPreExistingEntryWithoutMicFields() throws {
        let decoder = SessionJSONCoding.makeDecoder()
        let entry = try decoder.decode(DictationHistoryEntry.self, from: Data(Self.sampleJSON.utf8))

        #expect(entry.micDeviceName == nil)
        #expect(entry.micDeviceUID == nil)
    }

    @Test("round-trips mic_device_name/mic_device_uid, including the acronym-suffixed snake_case key (design 29 §3.2 addendum)")
    func roundTripsMicDeviceFields() throws {
        let original = DictationHistoryEntry(
            recordedAt: Date(timeIntervalSince1970: 1_751_000_400),
            durationMs: 3_000,
            targetBundleId: "com.apple.TextEdit",
            rawText: "マイクのテスト",
            refinedText: nil,
            finalText: "マイクのテスト",
            refineOutcome: .disabled,
            refineError: nil,
            insertOutcome: .inserted,
            llmUsage: nil,
            micDeviceName: "MacBook Proのマイク",
            micDeviceUID: "BuiltInMicrophoneDevice"
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["mic_device_name"] as? String == "MacBook Proのマイク")
        #expect(object["mic_device_uid"] as? String == "BuiltInMicrophoneDevice")

        let decoded = try decoder.decode(DictationHistoryEntry.self, from: data)
        #expect(decoded == original)
        #expect(decoded.micDeviceName == "MacBook Proのマイク")
        #expect(decoded.micDeviceUID == "BuiltInMicrophoneDevice")
    }

    @Test("round-trips a nil mic device (system default input, no config override)")
    func roundTripsNilMicDeviceFields() throws {
        let original = DictationHistoryEntry(
            recordedAt: Date(timeIntervalSince1970: 1_751_000_500),
            durationMs: 1_500,
            targetBundleId: nil,
            rawText: "デフォルトマイク",
            refinedText: nil,
            finalText: "デフォルトマイク",
            refineOutcome: .disabled,
            refineError: nil,
            insertOutcome: .inserted,
            llmUsage: nil,
            micDeviceName: "MacBook Proのマイク",
            micDeviceUID: nil
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(DictationHistoryEntry.self, from: data)

        #expect(decoded == original)
        #expect(decoded.micDeviceUID == nil)
    }

    @Test("encodes keys as snake_case, including insert_outcome's aborted_and_stashed raw value")
    func encodesSnakeCaseKeysAndRawValues() throws {
        let entry = DictationHistoryEntry(
            recordedAt: Date(timeIntervalSince1970: 0),
            durationMs: 1_000,
            targetBundleId: nil,
            rawText: "raw",
            refinedText: nil,
            finalText: "raw",
            refineOutcome: .fallback,
            refineError: "timedOut(3.0 seconds)",
            insertOutcome: .abortedAndStashed,
            llmUsage: nil
        )

        let data = try SessionJSONCoding.makeEncoder().encode(entry)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["recorded_at"] != nil)
        #expect(object["duration_ms"] as? Int == 1_000)
        // Synthesized `Encodable` calls `encodeIfPresent` for `Optional` properties, which omits the
        // key entirely for `nil` rather than writing a JSON `null` literal (unlike section 3.2's
        // sample JSON, which shows `null` only to illustrate the field's *decoded* meaning) --
        // `decodeIfPresent` treats "key absent" and "key present with `null`" identically, so this
        // doesn't affect round-tripping (see the other tests above), only this raw-JSON assertion.
        #expect(object["target_bundle_id"] == nil)
        #expect(object["raw_text"] as? String == "raw")
        #expect(object["final_text"] as? String == "raw")
        #expect(object["refine_outcome"] as? String == "fallback")
        #expect(object["refine_error"] as? String == "timedOut(3.0 seconds)")
        #expect(object["insert_outcome"] as? String == "aborted_and_stashed")
        #expect(object["targetBundleId"] == nil)
        #expect(object["durationMs"] == nil)
    }
}
