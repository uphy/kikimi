import Foundation
import Testing

@testable import Kikimi

// MARK: - TranscriptSegment

@Suite("TranscriptSegment")
struct TranscriptSegmentTests {
    /// kikimi.md 5 章 sample JSON.
    static let sampleJSON = """
    {
      "id": "seg_00042",
      "start_ms": 125300,
      "end_ms": 128100,
      "speaker": "mic",
      "text": "そうですね、次のスプリントで対応します",
      "confidence": 0.87
    }
    """

    @Test("decodes kikimi.md's sample JSON, converting snake_case keys")
    func decodesSampleJSON() throws {
        let decoder = SessionJSONCoding.makeDecoder()
        let segment = try decoder.decode(TranscriptSegment.self, from: Data(Self.sampleJSON.utf8))

        #expect(segment.id == "seg_00042")
        #expect(segment.startMs == 125_300)
        #expect(segment.endMs == 128_100)
        #expect(segment.speaker == .mic)
        #expect(segment.text == "そうですね、次のスプリントで対応します")
        #expect(segment.confidence == 0.87)
    }

    @Test("round-trips through the shared encoder/decoder")
    func roundTrips() throws {
        let original = TranscriptSegment(
            id: "seg_00001",
            startMs: 0,
            endMs: 1_500,
            speaker: .system,
            text: "了解しました",
            confidence: 0.95
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TranscriptSegment.self, from: data)

        #expect(decoded == original)
    }

    @Test("encodes keys as snake_case")
    func encodesSnakeCaseKeys() throws {
        let segment = TranscriptSegment(id: "seg_00001", startMs: 0, endMs: 1, speaker: .mic, text: "x", confidence: 1.0)
        let data = try SessionJSONCoding.makeEncoder().encode(segment)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["start_ms"] != nil)
        #expect(object?["end_ms"] != nil)
        #expect(object?["startMs"] == nil)
    }

    // MARK: sttSource (docs/design/33-meeting-two-pass-decode.md MT9)

    @Test("round-trips a batch-sourced segment, encoding sttSource as the stt_source key")
    func roundTripsWithSttSource() throws {
        let original = TranscriptSegment(
            id: "seg_00001",
            startMs: 0,
            endMs: 1_500,
            speaker: .mic,
            text: "了解しました",
            confidence: 0.95,
            sttSource: "batch"
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TranscriptSegment.self, from: data)

        #expect(decoded == original)
        #expect(decoded.sttSource == "batch")

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["stt_source"] as? String == "batch")
    }

    @Test("omits the stt_source key entirely when sttSource is nil (MT9: OFF/fallback stays byte-for-byte unchanged)")
    func omitsSttSourceKeyWhenNil() throws {
        let segment = TranscriptSegment(id: "seg_00001", startMs: 0, endMs: 1, speaker: .mic, text: "x", confidence: 1.0)
        #expect(segment.sttSource == nil)

        let data = try SessionJSONCoding.makeEncoder().encode(segment)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["stt_source"] == nil)
        #expect(object.keys.contains("stt_source") == false)
    }

    @Test("decodes a stt_source-less line (pre-design-33 session) as sttSource == nil, for backward compatibility")
    func decodesMissingSttSourceKeyAsNil() throws {
        // `sampleJSON` predates design 33 and has no `stt_source` key at all.
        let decoder = SessionJSONCoding.makeDecoder()
        let segment = try decoder.decode(TranscriptSegment.self, from: Data(Self.sampleJSON.utf8))

        #expect(segment.sttSource == nil)
    }
}

// MARK: - RefinedSegment

@Suite("RefinedSegment")
struct RefinedSegmentTests {
    /// kikimi.md 5 章 sample JSON.
    static let sampleJSON = """
    {
      "id": "seg_00042",
      "start_ms": 125300,
      "end_ms": 128100,
      "speaker": "mic",
      "raw_text": "そうですね、次のスプリントで対応します",
      "refined_text": "次のスプリントで対応します。",
      "refined_at": "2026-07-01T14:32:15Z",
      "model": "claude-haiku-4-5-20251001",
      "batch_id": "batch_00004"
    }
    """

    @Test("decodes kikimi.md's sample JSON, including the ISO 8601 refined_at timestamp")
    func decodesSampleJSON() throws {
        let decoder = SessionJSONCoding.makeDecoder()
        let segment = try decoder.decode(RefinedSegment.self, from: Data(Self.sampleJSON.utf8))

        #expect(segment.id == "seg_00042")
        #expect(segment.startMs == 125_300)
        #expect(segment.endMs == 128_100)
        #expect(segment.speaker == .mic)
        #expect(segment.rawText == "そうですね、次のスプリントで対応します")
        #expect(segment.refinedText == "次のスプリントで対応します。")
        #expect(segment.error == nil)
        #expect(segment.model == "claude-haiku-4-5-20251001")
        #expect(segment.batchId == "batch_00004")
        // `sampleJSON` above predates 段階1 and has no `source_seg_ids` key at all: the defensive
        // `init(from:)` fallback (SessionModels.swift, §15.2.1) must read that back as `[id]` rather
        // than throwing.
        #expect(segment.sourceSegIds == ["seg_00042"])

        var expectedComponents = DateComponents()
        expectedComponents.year = 2026
        expectedComponents.month = 7
        expectedComponents.day = 1
        expectedComponents.hour = 14
        expectedComponents.minute = 32
        expectedComponents.second = 15
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let expectedDate = utcCalendar.date(from: expectedComponents)!
        #expect(segment.refinedAt == expectedDate)
    }

    @Test("encodes refinedAt as an ISO 8601 string, not epoch seconds")
    func encodesRefinedAtAsISO8601String() throws {
        let decoder = SessionJSONCoding.makeDecoder()
        let segment = try decoder.decode(RefinedSegment.self, from: Data(Self.sampleJSON.utf8))

        let data = try SessionJSONCoding.makeEncoder().encode(segment)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["refined_at"] as? String == "2026-07-01T14:32:15Z")
    }

    @Test("round-trips a failed-refinement segment (refined_text/error set, nil otherwise)")
    func roundTripsFailure() throws {
        let original = RefinedSegment(
            id: "seg_00099",
            startMs: 1_000,
            endMs: 2_000,
            speaker: .system,
            rawText: "raw",
            refinedText: nil,
            error: "API timeout",
            refinedAt: Date(timeIntervalSince1970: 1_751_000_000),
            model: "claude-haiku-4-5-20251001",
            batchId: "batch_00005"
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(RefinedSegment.self, from: data)

        #expect(decoded == original)
        #expect(decoded.refinedText == nil)
        #expect(decoded.error == "API timeout")
    }

    @Test("a constructor call with no sourceSegIds argument defaults it to [id] (every pre-段階1 call site)")
    func constructorDefaultsSourceSegIdsToId() {
        let segment = RefinedSegment(
            id: "seg_00100",
            startMs: 0,
            endMs: 500,
            speaker: .mic,
            rawText: "raw",
            refinedText: "refined",
            error: nil,
            refinedAt: Date(timeIntervalSince1970: 1_751_000_000),
            model: "claude-haiku-4-5-20251001",
            batchId: "batch_00001"
        )

        #expect(segment.sourceSegIds == ["seg_00100"])
    }

    @Test("round-trips a merged unit's source_seg_ids (§15.2.1), preserving order and multiple entries")
    func roundTripsMergedSourceSegIds() throws {
        let original = RefinedSegment(
            id: "seg_00042",
            startMs: 125_300,
            endMs: 130_000,
            speaker: .mic,
            rawText: "そうですね次のスプリントで対応します",
            refinedText: "次のスプリントで対応します。",
            error: nil,
            refinedAt: Date(timeIntervalSince1970: 1_751_000_000),
            model: "claude-haiku-4-5-20251001",
            batchId: "batch_00004",
            sourceSegIds: ["seg_00042", "seg_00043", "seg_00044"]
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(RefinedSegment.self, from: data)

        #expect(decoded == original)
        #expect(decoded.sourceSegIds == ["seg_00042", "seg_00043", "seg_00044"])

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["source_seg_ids"] as? [String] == ["seg_00042", "seg_00043", "seg_00044"])
    }

    @Test("indexedBySourceSegId() maps every covered raw seg_id to its owning (possibly merged) unit")
    func indexedBySourceSegIdExpandsMergedUnits() {
        let leader = RefinedSegment(
            id: "seg_00001",
            startMs: 0,
            endMs: 1_000,
            speaker: .mic,
            rawText: "raw1raw2",
            refinedText: "refined1refined2",
            error: nil,
            refinedAt: Date(timeIntervalSince1970: 1_751_000_000),
            model: "claude-haiku-4-5-20251001",
            batchId: "batch_00001",
            sourceSegIds: ["seg_00001", "seg_00002"]
        )
        let standalone = RefinedSegment(
            id: "seg_00003",
            startMs: 1_000,
            endMs: 1_500,
            speaker: .mic,
            rawText: "raw3",
            refinedText: "refined3",
            error: nil,
            refinedAt: Date(timeIntervalSince1970: 1_751_000_000),
            model: "claude-haiku-4-5-20251001",
            batchId: "batch_00001"
        )

        let indexed = [leader, standalone].indexedBySourceSegId()

        #expect(indexed["seg_00001"] == leader)
        #expect(indexed["seg_00002"] == leader, "the covered (non-leading) source id must resolve to the same merged unit")
        #expect(indexed["seg_00003"] == standalone)
        #expect(indexed["seg_00004"] == nil)
    }
}

// MARK: - SessionMeta

@Suite("SessionMeta")
struct SessionMetaTests {
    /// kikimi.md 5 章 sample JSON.
    static let sampleJSON = """
    {
      "id": "2026-07-01T14-30-00_a1b2c3d4",
      "title": "デイリースクラム",
      "title_auto_generated": true,
      "title_auto_named_once": true,
      "title_proposal": null,
      "state": "ended",
      "created_at": "2026-07-01T14:28:12Z",
      "started_at": "2026-07-01T14:30:00Z",
      "ended_at": "2026-07-01T15:15:22Z",
      "duration_ms": 2722000,
      "based_on_session": "2026-06-24T14-30-00_x9y8z7w6",
      "segment_count": 342,
      "refined_count": 342,
      "app_version": "0.1.0"
    }
    """

    @Test("decodes kikimi.md's sample JSON")
    func decodesSampleJSON() throws {
        let decoder = SessionJSONCoding.makeDecoder()
        let meta = try decoder.decode(SessionMeta.self, from: Data(Self.sampleJSON.utf8))

        #expect(meta.id == "2026-07-01T14-30-00_a1b2c3d4")
        #expect(meta.title == "デイリースクラム")
        #expect(meta.titleAutoGenerated == true)
        #expect(meta.titleAutoNamedOnce == true)
        #expect(meta.titleProposal == nil)
        #expect(meta.state == .ended)
        #expect(meta.durationMs == 2_722_000)
        #expect(meta.basedOnSession == "2026-06-24T14-30-00_x9y8z7w6")
        #expect(meta.segmentCount == 342)
        #expect(meta.refinedCount == 342)
        #expect(meta.appVersion == "0.1.0")
        #expect(meta.startedAt != nil)
        #expect(meta.endedAt != nil)
        // `sampleJSON` above has no `recordings` key at all: the defensive `init(from:)` fallback
        // (SessionModels.swift) must decode that as an empty array rather than throwing.
        #expect(meta.recordings.isEmpty)
    }

    @Test("decodes kikimi.md's sample recordings[] (two segments spanning a pause/resume)")
    func decodesSampleRecordings() throws {
        let sample = """
        {
          "id": "2026-07-01T14-30-00_a1b2c3d4",
          "title": "デイリースクラム",
          "title_auto_generated": true,
          "title_auto_named_once": true,
          "title_proposal": null,
          "state": "ended",
          "created_at": "2026-07-01T14:28:12Z",
          "started_at": "2026-07-01T14:30:00Z",
          "ended_at": "2026-07-01T15:15:22Z",
          "duration_ms": 2722000,
          "recordings": [
            { "index": 0, "started_at": "2026-07-01T14:30:00Z", "ended_at": "2026-07-01T14:52:10Z", "start_ms_offset": 0 },
            { "index": 1, "started_at": "2026-07-01T15:05:30Z", "ended_at": "2026-07-01T15:15:22Z", "start_ms_offset": 1330000 }
          ],
          "based_on_session": null,
          "segment_count": 342,
          "refined_count": 342,
          "app_version": "0.1.0"
        }
        """
        let meta = try SessionJSONCoding.makeDecoder().decode(SessionMeta.self, from: Data(sample.utf8))

        #expect(meta.recordings.count == 2)
        #expect(meta.recordings[0].index == 0)
        #expect(meta.recordings[0].startMsOffset == 0)
        #expect(meta.recordings[0].endedAt != nil)
        #expect(meta.recordings[1].index == 1)
        #expect(meta.recordings[1].startMsOffset == 1_330_000)
        #expect(meta.recordings[1].endedAt != nil)
    }

    @Test("encodes date fields as ISO 8601 strings ('2026-07-01T14:28:12Z' style), not epoch seconds")
    func encodesDatesAsISO8601Strings() throws {
        let decoder = SessionJSONCoding.makeDecoder()
        let meta = try decoder.decode(SessionMeta.self, from: Data(Self.sampleJSON.utf8))

        let data = try SessionJSONCoding.makeEncoder().encode(meta)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["created_at"] as? String == "2026-07-01T14:28:12Z")
        #expect(object?["started_at"] as? String == "2026-07-01T14:30:00Z")
        #expect(object?["ended_at"] as? String == "2026-07-01T15:15:22Z")
    }

    @Test("round-trips a Draft session (startedAt/endedAt/durationMs/titleProposal nil)")
    func roundTripsDraftSession() throws {
        let original = SessionMeta(
            id: "2026-07-02T09-00-00_deadbeef",
            title: "",
            titleAutoGenerated: true,
            titleAutoNamedOnce: false,
            titleProposal: nil,
            state: .draft,
            createdAt: Date(timeIntervalSince1970: 1_751_000_000),
            startedAt: nil,
            endedAt: nil,
            durationMs: 0,
            basedOnSession: nil,
            segmentCount: 0,
            refinedCount: 0,
            appVersion: "0.1.0"
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SessionMeta.self, from: data)

        #expect(decoded == original)
    }

    @Test("round-trips a session with a snake_case start_ms_offset field inside recordings[]")
    func roundTripsRecordingsWithSnakeCaseFields() throws {
        let original = SessionMeta(
            id: "2026-07-02T09-00-00_deadbeef",
            title: "デイリースクラム",
            titleAutoGenerated: true,
            titleAutoNamedOnce: true,
            titleProposal: nil,
            state: .paused,
            createdAt: Date(timeIntervalSince1970: 1_751_000_000),
            startedAt: Date(timeIntervalSince1970: 1_751_000_100),
            endedAt: nil,
            durationMs: 1_330_000,
            recordings: [
                RecordingSegment(
                    index: 0,
                    startedAt: Date(timeIntervalSince1970: 1_751_000_100),
                    endedAt: Date(timeIntervalSince1970: 1_751_001_430),
                    startMsOffset: 0
                ),
                RecordingSegment(
                    index: 1,
                    startedAt: Date(timeIntervalSince1970: 1_751_002_000),
                    endedAt: nil,
                    startMsOffset: 1_330_000
                )
            ],
            basedOnSession: nil,
            segmentCount: 10,
            refinedCount: 10,
            appVersion: "0.1.0"
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let jsonObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let recordingsJSON = try #require(jsonObject["recordings"] as? [[String: Any]])
        #expect(recordingsJSON[0]["start_ms_offset"] as? Int == 0)
        #expect(recordingsJSON[1]["start_ms_offset"] as? Int == 1_330_000)

        let decoded = try decoder.decode(SessionMeta.self, from: data)
        #expect(decoded == original)
        #expect(decoded.recordings[1].endedAt == nil)
    }

    @Test("recordingIndex(atStartMs:) resolves the recording segment owning a cumulative-timeline position (§15.2.3)")
    func recordingIndexResolvesOwningSegment() {
        let meta = SessionMeta(
            id: "2026-07-02T09-00-00_deadbeef",
            title: "t",
            titleAutoGenerated: true,
            titleAutoNamedOnce: false,
            titleProposal: nil,
            state: .recording,
            createdAt: Date(timeIntervalSince1970: 0),
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: nil,
            durationMs: 0,
            recordings: [
                RecordingSegment(index: 0, startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 100), startMsOffset: 0),
                RecordingSegment(index: 1, startedAt: Date(timeIntervalSince1970: 200), endedAt: nil, startMsOffset: 1_330_000)
            ],
            basedOnSession: nil,
            segmentCount: 0,
            refinedCount: 0,
            appVersion: "0.1.0"
        )

        #expect(meta.recordingIndex(atStartMs: 0) == 0)
        #expect(meta.recordingIndex(atStartMs: 500_000) == 0)
        #expect(meta.recordingIndex(atStartMs: 1_329_999) == 0)
        #expect(meta.recordingIndex(atStartMs: 1_330_000) == 1)
        #expect(meta.recordingIndex(atStartMs: 2_000_000) == 1)
    }

    @Test("recordingIndex(atStartMs:) defaults to 0 for a session with no recordings at all")
    func recordingIndexDefaultsToZeroWithNoRecordings() {
        let meta = SessionMeta(
            id: "2026-07-02T09-00-00_deadbeef",
            title: "t",
            titleAutoGenerated: true,
            titleAutoNamedOnce: false,
            titleProposal: nil,
            state: .draft,
            createdAt: Date(timeIntervalSince1970: 0),
            startedAt: nil,
            endedAt: nil,
            durationMs: 0,
            basedOnSession: nil,
            segmentCount: 0,
            refinedCount: 0,
            appVersion: "0.1.0"
        )

        #expect(meta.recordingIndex(atStartMs: 0) == 0)
    }

    @Test("updateMeta-style read-modify-write is idempotent when applied twice with the same mutation")
    func readModifyWriteIsIdempotent() throws {
        let decoder = SessionJSONCoding.makeDecoder()
        let encoder = SessionJSONCoding.makeEncoder()
        var meta = try decoder.decode(SessionMeta.self, from: Data(Self.sampleJSON.utf8))

        func applyTitleUpdate(_ meta: inout SessionMeta) {
            meta.title = "デイリースクラム"
            meta.titleAutoGenerated = false
        }

        // Compare the *decoded* round trip rather than raw encoded `Data`: `SessionJSONCoding.makeEncoder()`
        // deliberately does not set `.sortedKeys` (unlike the old `SessionJSON.makeEncoder()`), so byte-for-byte
        // key ordering is not a guaranteed invariant of the encoder and can differ between two otherwise-identical
        // encode() calls when this test suite's tests run concurrently. `SessionMeta`'s own `Equatable`
        // conformance is the actual idempotency contract worth asserting here.
        applyTitleUpdate(&meta)
        let firstData = try encoder.encode(meta)
        let firstDecoded = try decoder.decode(SessionMeta.self, from: firstData)

        applyTitleUpdate(&meta)
        let secondData = try encoder.encode(meta)
        let secondDecoded = try decoder.decode(SessionMeta.self, from: secondData)

        #expect(firstDecoded == secondDecoded)
    }
}

// MARK: - SessionJSONCoding

@Suite("SessionJSONCoding")
struct SessionJSONCodingTests {
    @Test("makeEncoder uses convertToSnakeCase and iso8601 date strategies")
    func encoderConfiguration() throws {
        struct Fixture: Codable {
            var someField: Int
            var someDate: Date
        }

        let fixture = Fixture(someField: 1, someDate: Date(timeIntervalSince1970: 0))
        let data = try SessionJSONCoding.makeEncoder().encode(fixture)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["some_field"] as? Int == 1)
        #expect(object?["some_date"] as? String == "1970-01-01T00:00:00Z")
    }

    @Test("makeDecoder uses convertFromSnakeCase and iso8601 date strategies")
    func decoderConfiguration() throws {
        struct Fixture: Codable, Equatable {
            var someField: Int
            var someDate: Date
        }

        let json = """
        {"some_field": 1, "some_date": "1970-01-01T00:00:00Z"}
        """
        let decoded = try SessionJSONCoding.makeDecoder().decode(Fixture.self, from: Data(json.utf8))

        #expect(decoded.someField == 1)
        #expect(decoded.someDate == Date(timeIntervalSince1970: 0))
    }

    @Test("makeEncoder/makeDecoder each return a fresh instance (no shared mutable state)")
    func returnsFreshInstances() {
        let encoderA = SessionJSONCoding.makeEncoder()
        let encoderB = SessionJSONCoding.makeEncoder()
        #expect(encoderA !== encoderB)

        let decoderA = SessionJSONCoding.makeDecoder()
        let decoderB = SessionJSONCoding.makeDecoder()
        #expect(decoderA !== decoderB)
    }
}
