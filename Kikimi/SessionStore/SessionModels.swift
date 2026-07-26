import Foundation

// MARK: - TranscriptSegment

/// One line of `transcript.jsonl` (raw, unrefined transcription output). See
/// `docs/design/07-session-store.md` section 5.3 and kikimi.md 5 章.
///
/// `speaker` reuses `AudioSourceKind` (`Kikimi/AudioCapture/AudioCaptureTypes.swift`) rather than
/// redefining a duplicate mic/system enum, since the value is the same physical-source
/// attribution `AudioCapture` already produces.
struct TranscriptSegment: Codable, Sendable, Equatable {
    /// `"seg_"` + 5-digit zero-padded sequence number, assigned in insertion order by
    /// `SessionHandle.appendTranscriptSegment(...)`.
    var id: String
    /// Milliseconds elapsed since session start.
    var startMs: Int
    /// Milliseconds elapsed since session start.
    var endMs: Int
    var speaker: AudioSourceKind
    /// The STT output the segment was confirmed with (batch re-decode or streaming; design 33).
    var text: String
    /// STT confidence, `0.0`...`1.0`.
    var confidence: Double
    /// Supply source of `text` when two-pass decode (`docs/design/33-meeting-two-pass-decode.md`
    /// MT9) is on: `"batch"` when the batch re-decode succeeded, `nil` when the segment fell back
    /// to the streaming-confirmed text or two-pass decode is off. `nil` is omitted from the encoded
    /// JSON entirely (optional on a synthesized `Codable` conformance), so an OFF session's
    /// `transcript.jsonl` line is byte-for-byte unchanged from before this field existed (MT9/MT10
    /// compatibility guarantee) and pre-design-33 sessions decode this back as `nil` (design 29
    /// §3.2's `mic_device` precedent).
    var sttSource: String?
}

// MARK: - RefinedSegment

/// One line of `refined.jsonl` (Haiku-refined transcription output). Shares `id`/timing/`speaker`
/// with the leading `TranscriptSegment` it refines. See `docs/design/07-session-store.md` section
/// 5.3, kikimi.md 5 章, and `docs/design/03-refinement-batch.md` §15.2.1: since 段階1 (LLM
/// re-segmentation), a row is a "derived unit" that covers one **or more** raw `seg_id`s
/// (`sourceSegIds`) rather than always exactly one.
struct RefinedSegment: Codable, Sendable, Equatable {
    /// This derived unit's id -- always `sourceSegIds.first` (the leading/leftmost raw seg_id it
    /// covers), kept as its own field for backward-compatible id-keyed lookups.
    var id: String
    var startMs: Int
    var endMs: Int
    var speaker: AudioSourceKind
    var rawText: String
    /// `nil` when refinement failed for this segment; `error` then holds the failure message.
    var refinedText: String?
    /// Failure message when `refinedText == nil`; `nil` on success.
    var error: String?
    var refinedAt: Date
    var model: String
    /// Identifies the batch (single Haiku call) this segment was refined alongside, for
    /// debugging/retry decisions.
    var batchId: String
    /// Every raw `TranscriptSegment.id` this derived unit covers, `startMs` ascending
    /// (`docs/design/03-refinement-batch.md` §15.2.1). `[id]` for the common 1:1 case; more than one
    /// entry only when `RefinementMerge`'s deterministic merge gate folded adjacent segments
    /// together. `id` always equals `sourceSegIds.first`.
    var sourceSegIds: [String]

    /// - Parameter sourceSegIds: Defaults to `[id]` (the common 1:1 case) when left empty, so every
    ///   call site written before 段階1 (merge) continues to compile and behave unchanged. Pass an
    ///   explicit multi-element array (`startMs` ascending) only when constructing an
    ///   already-merged unit (`RefinementMerge`).
    init(
        id: String,
        startMs: Int,
        endMs: Int,
        speaker: AudioSourceKind,
        rawText: String,
        refinedText: String?,
        error: String?,
        refinedAt: Date,
        model: String,
        batchId: String,
        sourceSegIds: [String] = []
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
        self.rawText = rawText
        self.refinedText = refinedText
        self.error = error
        self.refinedAt = refinedAt
        self.model = model
        self.batchId = batchId
        self.sourceSegIds = sourceSegIds.isEmpty ? [id] : sourceSegIds
    }

    /// Defensive decode (mirrors `DiarizationConfig.init(from:)`'s pattern,
    /// `Kikimi/Config/AppConfig.swift`): a `refined.jsonl` row written before 段階1 has no
    /// `source_seg_ids` key at all, and reads back as `[id]` rather than throwing.
    ///
    /// No explicit `CodingKeys` on purpose, unlike `DiarizationConfig`: that type's `CodingKeys`
    /// give every case an explicit snake_case *string* raw value (e.g. `case selfName =
    /// "self_name"`), which is the right shape for `AppConfig`'s Yams-backed YAML decode, but is
    /// actively wrong here -- `SessionJSONCoding`'s `JSONDecoder`/`JSONEncoder` already apply
    /// `.convertFromSnakeCase`/`.convertToSnakeCase` globally, and that conversion *replaces* each
    /// incoming JSON key with its camelCase form before matching against `CodingKeys.stringValue`.
    /// An explicit `"source_seg_ids"` raw value would therefore never match the
    /// already-camelCase-converted `"sourceSegIds"` key the decoder actually looks up, so
    /// `decodeIfPresent(forKey:)` would silently return `nil` on *every* call, no matter what the
    /// JSON contains (verified empirically before writing this). Leaving `CodingKeys` un-declared
    /// lets it auto-synthesize with implicit (property-name-matching) raw values instead, which do
    /// interact correctly with the global snake_case strategies -- `encode(to:)` is synthesized the
    /// same way, so this file only needs to override `init(from:)`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        startMs = try container.decode(Int.self, forKey: .startMs)
        endMs = try container.decode(Int.self, forKey: .endMs)
        speaker = try container.decode(AudioSourceKind.self, forKey: .speaker)
        rawText = try container.decode(String.self, forKey: .rawText)
        refinedText = try container.decodeIfPresent(String.self, forKey: .refinedText)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        refinedAt = try container.decode(Date.self, forKey: .refinedAt)
        model = try container.decode(String.self, forKey: .model)
        batchId = try container.decode(String.self, forKey: .batchId)
        let decodedSourceSegIds = try container.decodeIfPresent([String].self, forKey: .sourceSegIds) ?? []
        sourceSegIds = decodedSourceSegIds.isEmpty ? [id] : decodedSourceSegIds
    }
}

extension [RefinedSegment] {
    /// Maps every raw `seg_id` any element covers (via `sourceSegIds`) to that owning derived unit
    /// (`docs/design/03-refinement-batch.md` §15.2.4/§15.2.5's "covered seg id 集合" generalization).
    /// For the common 1:1 case this is identical to keying by `id` alone; a merged unit additionally
    /// makes its non-leading `sourceSegIds` resolve to the same unit. Last-wins on conflicting
    /// duplicate ids (`uniquingKeysWith:`), matching the "防御の二重化" idiom every call site of this
    /// helper used inline before this generalization (§3.2).
    func indexedBySourceSegId() -> [String: RefinedSegment] {
        Dictionary(
            flatMap { unit in unit.sourceSegIds.map { ($0, unit) } },
            uniquingKeysWith: { _, last in last }
        )
    }
}

// MARK: - RecordingSegment

/// One recording segment (kikimi.md 4 章 "「停止」と「終了」を分離する" / 5 章): a contiguous span of
/// actual audio capture within a session. A new segment starts every time the session enters
/// `.recording` (initial start, resume from Paused, or reopen from Ended) and closes when it leaves
/// `.recording` (pause or end). `meta.json`'s `recordings` array is the ordered list of every
/// segment a session has ever had; `mic_NNN.wav`/`system_NNN.wav` (`index` zero-padded to 3 digits)
/// are written one pair per segment (kikimi.md 4 章 directory layout).
struct RecordingSegment: Codable, Sendable, Equatable {
    /// Zero-based, assigned in creation order. Matches the `NNN` in `mic_NNN.wav`/`system_NNN.wav`.
    var index: Int
    /// Wall-clock time this segment actually started (audio capture begins here).
    var startedAt: Date
    /// Wall-clock time this segment was closed (pause or end). `nil` while still the active segment.
    var endedAt: Date?
    /// This segment's starting position on the cumulative "recording active time" timeline
    /// (kikimi.md 5/6 章): equal to `meta.durationMs` at the moment this segment was opened. Every
    /// `TranscriptSegment.startMs`/`endMs` produced while this segment is active is
    /// `startMsOffset + <elapsed within this segment>`.
    var startMsOffset: Int
}

// MARK: - SessionMeta

/// `meta.json`: a session's metadata, created at Draft time and updated throughout its lifecycle.
/// See `docs/design/07-session-store.md` section 5.3/6 and kikimi.md 5 章.
struct SessionMeta: Codable, Sendable, Equatable {
    /// Session folder name (`{ISO8601 createdAt}_{short UUID}`). See section 5.3.1: this is
    /// derived from `createdAt` (Draft creation time), not `startedAt`, and never renamed.
    var id: String
    var title: String
    /// `false` once the user manually edits the title; auto-naming/proposal badges stop.
    var titleAutoGenerated: Bool
    /// Whether the once-only Recording-time auto title reflection (kikimi.md 8 章) has already
    /// happened for this session.
    var titleAutoNamedOnce: Bool
    /// Current suggested title (if any), surfaced as a "adopt" badge in the UI.
    var titleProposal: String?
    var state: SessionState
    /// Draft window creation time. Source of `id`/folder name (section 5.3.1).
    var createdAt: Date
    /// The *first* recording start time (kikimi.md 5 章: "`started_at` は最初の録音開始時刻（不変）");
    /// `nil` while still Draft. Never updated again by a later pause/resume.
    var startedAt: Date?
    /// The meeting-end (Ended) time; `nil` while Recording/Paused (kikimi.md 5 章: "一時停止では埋めない").
    var endedAt: Date?
    /// Cumulative recording-active time across every closed `recordings[]` segment, in
    /// milliseconds (kikimi.md 5 章). Updated as each segment closes, not only at Ended. `0` for a
    /// session that has never recorded.
    var durationMs: Int
    /// Every recording segment this session has ever had, in creation order (kikimi.md 4/5 章). The
    /// last element's `endedAt == nil` iff the session is currently `.recording`.
    var recordings: [RecordingSegment]
    /// Source session id if this session was created via "duplicate as new workspace".
    var basedOnSession: String?
    var segmentCount: Int
    var refinedCount: Int
    var appVersion: String

    init(
        id: String,
        title: String,
        titleAutoGenerated: Bool,
        titleAutoNamedOnce: Bool,
        titleProposal: String?,
        state: SessionState,
        createdAt: Date,
        startedAt: Date?,
        endedAt: Date?,
        durationMs: Int,
        recordings: [RecordingSegment] = [],
        basedOnSession: String?,
        segmentCount: Int,
        refinedCount: Int,
        appVersion: String
    ) {
        self.id = id
        self.title = title
        self.titleAutoGenerated = titleAutoGenerated
        self.titleAutoNamedOnce = titleAutoNamedOnce
        self.titleProposal = titleProposal
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMs = durationMs
        self.recordings = recordings
        self.basedOnSession = basedOnSession
        self.segmentCount = segmentCount
        self.refinedCount = refinedCount
        self.appVersion = appVersion
    }

    /// Resolves which `recordings[]` entry owns a given cumulative-timeline `startMs` position
    /// (`docs/design/03-refinement-batch.md` §15.2.3's merge-gate "same recording index" guard):
    /// the recording segment with the greatest `startMsOffset <= startMs`, mirroring
    /// `SegmentPlaybackResolver.resolve(startMs:endMs:recordings:)`'s own owner-lookup rule.
    /// Defensively falls back to the earliest known segment (or `0` for a session with no
    /// `recordings` at all) for an out-of-range value rather than crashing -- the merge gate only
    /// needs "do these two positions fall in the same bucket", not an authoritative index.
    func recordingIndex(atStartMs startMs: Int) -> Int {
        let sorted = recordings.sorted { $0.startMsOffset < $1.startMsOffset }
        return sorted.last(where: { $0.startMsOffset <= startMs })?.index ?? sorted.first?.index ?? 0
    }

    /// Custom `init(from:)` so that `recordings` (added alongside the pause/resume/end-meeting
    /// model) and `durationMs`'s changed non-optional shape both decode defensively rather than
    /// crashing: no real `meta.json` on disk predates this change (this project has no users yet,
    /// so no on-disk migration is needed), but a hand-edited or partially-written fixture missing
    /// either key should still decode as "no segments yet" / "no accumulated duration" rather than
    /// throwing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        titleAutoGenerated = try container.decode(Bool.self, forKey: .titleAutoGenerated)
        titleAutoNamedOnce = try container.decode(Bool.self, forKey: .titleAutoNamedOnce)
        titleProposal = try container.decodeIfPresent(String.self, forKey: .titleProposal)
        state = try container.decode(SessionState.self, forKey: .state)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        recordings = try container.decodeIfPresent([RecordingSegment].self, forKey: .recordings) ?? []
        basedOnSession = try container.decodeIfPresent(String.self, forKey: .basedOnSession)
        segmentCount = try container.decode(Int.self, forKey: .segmentCount)
        refinedCount = try container.decode(Int.self, forKey: .refinedCount)
        appVersion = try container.decode(String.self, forKey: .appVersion)
    }
}

// MARK: - SessionJSONCoding

/// Shared `JSONEncoder`/`JSONDecoder` factory for all session JSON I/O (`meta.json`,
/// `transcript.jsonl`, `refined.jsonl`, and any other session file `SessionHandle` persists as
/// JSON). See `docs/design/07-session-store.md` section 5.3.
///
/// kikimi.md 5 章's sample JSON serializes `Date` fields (`created_at`/`started_at`/`ended_at`/
/// `refined_at`) as ISO 8601 strings (e.g. `"2026-07-01T14:28:12Z"`), not the `JSONEncoder`/
/// `JSONDecoder` default `.deferredToDate` (Unix epoch seconds). Every encoder/decoder used for
/// session JSON must therefore be created through this factory rather than `JSONEncoder()`/
/// `JSONDecoder()` directly, so the `.iso8601` date strategy and `snake_case` key strategy stay
/// consistent across all call sites (`SessionHandle`'s JSON I/O reuses these, per the module task
/// for `SessionModels`).
enum SessionJSONCoding {
    /// Encoder for session JSON files: `camelCase` Swift properties are written as `snake_case`
    /// keys, and `Date` fields are written as ISO 8601 strings.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Decoder for session JSON files: `snake_case` keys are read into `camelCase` Swift
    /// properties, and `Date` fields are parsed from ISO 8601 strings.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
