import Foundation

// MARK: - DiarizationTurn

/// One line of `diarization.jsonl` (append-only): a finalized speaker turn emitted by the
/// realtime diarizer. See `docs/design/13-speaker-diarization.md` section 4.2.
///
/// Times are on the cumulative "recording active time" timeline (the same axis as
/// `TranscriptSegment.startMs`), already adjusted by the coordinator's base offset
/// (design section 5.1). Turns may overlap (simultaneous speech), and append order does not
/// guarantee `startMs` ascending — readers must sort by time.
struct DiarizationTurn: Codable, Sendable, Equatable {
    /// Session-scoped slot ID (`"spk_"` + 1-based sequence). Assigned once by the coordinator,
    /// never renumbered and never reused within a session (design section 5.1).
    var slot: String
    var startMs: Int
    var endMs: Int
}

// MARK: - SpeakerAssignments

/// `speaker_assignments.json`: slot → display-name mapping (design section 4.3). Whole-file
/// overwrite, but only through a mutate-closure API on `SessionHandle` — auto assignments from
/// the diarization coordinator and user renames from the UI would otherwise race and lose
/// updates.
struct SpeakerAssignments: Codable, Sendable, Equatable {
    /// Keyed by slot ID (`"spk_1"`, ...).
    var assignments: [String: SlotAssignment]
    /// Per-segment display-name overrides, keyed by `TranscriptSegment.id` (`"seg_00042"`, ...):
    /// "この発言だけ変更" (design section 6.1). Takes priority over the slot-derived label at display
    /// time, so a single mis-attributed utterance inside an otherwise-correct slot (or a slotless
    /// "Speaker ?" row) can be named without renaming the whole slot. Removing the key restores the
    /// slot-derived label. Always user-authored; also doubles as labeled training data for future
    /// per-segment voiceprint classification (design section 14).
    var segmentOverrides: [String: SegmentSpeakerOverride]

    init(
        assignments: [String: SlotAssignment] = [:],
        segmentOverrides: [String: SegmentSpeakerOverride] = [:]
    ) {
        self.assignments = assignments
        self.segmentOverrides = segmentOverrides
    }

    /// Defensive decode: `segment_overrides` was added after `speaker_assignments.json` first
    /// shipped, so files written by earlier builds lack the key and must decode as "no overrides"
    /// rather than throwing (same pattern as `SessionMeta.init(from:)`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assignments = try container.decodeIfPresent([String: SlotAssignment].self, forKey: .assignments) ?? [:]
        segmentOverrides = try container.decodeIfPresent([String: SegmentSpeakerOverride].self, forKey: .segmentOverrides) ?? [:]
    }

    // MARK: - Rename propagation (design section 6.1)

    /// Slot IDs (excluding `slot` itself) already assigned to `globalSpeakerId` (design section 6.1:
    /// "同じ global_speaker_id を持つ全 slot"). A person can split across multiple slots within one
    /// session (design section 5.1: diarizer (re)creation at every Paused/resume boundary re-numbers
    /// slots from zero), so more than one slot may legitimately share the same global speaker.
    func slotsSharing(globalSpeakerId: String, excluding slot: String) -> [String] {
        assignments.compactMap { key, value in
            guard key != slot, value.globalSpeakerId == globalSpeakerId else { return nil }
            return key
        }.sorted()
    }

    /// Applies one rename (design section 6.1, "リネームは同一 slot（および同じ global_speaker_id を持つ全
    /// slot）の全セグメント表示に即時反映される") to `self`: writes `displayName`/`globalSpeakerId` as a
    /// `.user` assignment for `slot`, then does the same for every other slot already sharing
    /// `globalSpeakerId` (if non-`nil`) so every slot that resolves to the same person is renamed
    /// together. A pure, in-memory mutation -- the caller is responsible for persisting the result
    /// (`SessionHandle.updateSpeakerAssignments(_:)`). `embedding` is left untouched for every slot
    /// this touches, including `slot` itself (design section 4.4: renaming never updates an embedding
    /// -- only the Ended-time moving-average update and the coordinator's own extraction do).
    mutating func applyRename(slot: String, displayName: String, globalSpeakerId: String?) {
        let siblings = globalSpeakerId.map { slotsSharing(globalSpeakerId: $0, excluding: slot) } ?? []
        for target in [slot] + siblings {
            var current = assignments[target] ?? SlotAssignment()
            current.displayName = displayName
            current.globalSpeakerId = globalSpeakerId
            current.assignedBy = .user
            assignments[target] = current
        }
    }
}

/// One "この発言だけ変更" entry (design section 6.1): a user-chosen display name pinned to a single
/// transcript segment, independent of whatever slot (if any) diarization attributed it to.
struct SegmentSpeakerOverride: Codable, Sendable, Equatable {
    var displayName: String
    /// `VoiceprintSpeaker.id` this override resolved to, if any
    /// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 5.1): set when the popover's
    /// known-speaker picker was used, or when a free-typed name normalized (section 4) to exactly one
    /// existing speaker. `nil` for a brand-new typed name (not yet enrolled) or an ambiguous
    /// (same-name-duplicate) match that normalization deliberately declines to resolve. Doubles as the
    /// Ended-time enrollment write-back target once that lands (section 5.4 -- not yet implemented,
    /// out of this module's scope).
    ///
    /// The synthesized `Decodable` conformance's `decodeIfPresent` makes a pre-existing
    /// `speaker_assignments.json` (written before this field existed) decode as `nil` rather than
    /// throwing -- no custom `init(from:)` needed here (unlike `SpeakerAssignments` itself, which needs
    /// one for its *own* added-later key, `segmentOverrides`, only because that field has no usable
    /// zero-value default at the container level).
    var globalSpeakerId: String?

    /// Explicit memberwise init (rather than relying on the synthesized one, which SwiftLint's
    /// `implicit_optional_initialization` rule forbids giving an in-line `= nil` default on the stored
    /// property above) so existing call sites that only ever pass `displayName:` keep compiling.
    init(displayName: String, globalSpeakerId: String? = nil) {
        self.displayName = displayName
        self.globalSpeakerId = globalSpeakerId
    }
}

/// Assignment state of one slot (design section 4.3).
struct SlotAssignment: Codable, Sendable, Equatable {
    /// `voiceprints.json` speaker ID when matched or linked by the user; `nil` for anonymous
    /// slots.
    var globalSpeakerId: String?
    /// Resolved display name; `nil` renders as "Speaker N".
    var displayName: String?
    var assignedBy: SlotAssignmentSource?
    /// WeSpeaker voiceprint captured for this slot; `nil` until extraction succeeds. Persisted
    /// here (never only held in memory) so the Ended-time moving-average update and enrollment
    /// survive window close / process restart (design sections 4.3-4.4).
    var embedding: [Float]?

    init(
        globalSpeakerId: String? = nil,
        displayName: String? = nil,
        assignedBy: SlotAssignmentSource? = nil,
        embedding: [Float]? = nil
    ) {
        self.globalSpeakerId = globalSpeakerId
        self.displayName = displayName
        self.assignedBy = assignedBy
        self.embedding = embedding
    }
}

/// Who produced a slot assignment. A `user` assignment must never be overwritten by `auto`
/// (voiceprint matching); the reverse is always allowed (design section 4.3).
enum SlotAssignmentSource: String, Codable, Sendable {
    case auto
    case user
}

// MARK: - SessionParticipants

/// `sessions/<id>/participants.json`: the optional per-session participant roster
/// (`docs/design/22-participant-hints.md` section 1.1). Whole-file overwrite, always through
/// `SessionHandle.updateParticipants(_:)`'s mutate-closure API (mirrors `SpeakerAssignments`'
/// `updateSpeakerAssignments(_:)`, for the same "auto-add from a user action and a concurrent UI edit
/// could otherwise race" reason).
///
/// An empty roster (`participantIds.isEmpty`, the zero value returned for a missing/corrupt file) means
/// "no roster configured" -- voiceprint matching stays open-set (design section 2), this type's mere
/// presence never changes matching behavior on its own. Display names are deliberately not stored here;
/// they are always resolved from `voiceprints.json` by id (design section 1.1: "表示名は保存しない") so a
/// rename in Settings' speaker tab is reflected without touching this file.
struct SessionParticipants: Codable, Sendable, Equatable {
    /// The roster, in the order participants were added (design section 1.1: "追加順を保持（UI 表示順）").
    /// Each element is a `VoiceprintSpeaker.id`.
    var participantIds: [String]
    /// Speaker ids the user has explicitly removed from the roster this session (design section 1.1:
    /// "自動追加の抑止リスト"). `autoAddParticipantHint` (P2) consults this before re-adding a speaker id
    /// that an auto voiceprint match resolves to, so a manual removal is not silently undone by the next
    /// matching utterance. Disjoint from `participantIds` by construction -- see `addParticipant(_:)`/
    /// `removeParticipant(_:)` below, the only sanctioned mutators of either list.
    var removedParticipantIds: [String]

    init(participantIds: [String] = [], removedParticipantIds: [String] = []) {
        self.participantIds = participantIds
        self.removedParticipantIds = removedParticipantIds
    }

    /// Left at the default `camelCase` case names, same convention as every other `SessionJSONCoding`
    /// model in this file (see `VoiceprintSpeaker.CodingKeys`'s doc comment for why an explicit
    /// `snake_case` raw value here would double-convert and silently fail to round-trip).
    enum CodingKeys: String, CodingKey {
        case participantIds
        case removedParticipantIds
    }

    /// Defensive decode (mirrors `SpeakerAssignments.init(from:)` above): a missing/corrupt
    /// `participants.json`, or one written before either key existed, decodes as an empty roster --
    /// design section 1.1's "防御的 decode: ファイル欠落・破損・キー欠落は空... 空 = 名簿未設定 = オープンセット照合" --
    /// rather than throwing and blocking the meeting from being recorded/opened.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        participantIds = try container.decodeIfPresent([String].self, forKey: .participantIds) ?? []
        removedParticipantIds = try container.decodeIfPresent([String].self, forKey: .removedParticipantIds) ?? []
    }

    /// Adds `id` to the roster (design section 1.1: both lists are mutually exclusive by
    /// construction -- this is the only place `participantIds` grows). Removes `id` from
    /// `removedParticipantIds` first if present (design section 1.2 / `docs/design/22-participant-hints.md`
    /// section 4.1: "追加時、`removed_participant_ids` に居れば取り除く（手動再追加）") so a manual re-add moves the id
    /// between the two lists rather than letting it sit in both. A no-op if `id` is already in
    /// `participantIds` (idempotent; `autoAddParticipantHint`'s "既収載... なら no-op" contract, design
    /// section 4.1, relies on this instead of re-checking membership itself).
    mutating func addParticipant(_ id: String) {
        removedParticipantIds.removeAll { $0 == id }
        guard !participantIds.contains(id) else { return }
        participantIds.append(id)
    }

    /// Moves `id` out of `participantIds` and into `removedParticipantIds` (design section 1.1: "ユーザーが
    /// 手動削除した speaker id"), the mirror image of `addParticipant(_:)`. A no-op (still records the
    /// removal) if `id` was never in `participantIds` to begin with -- `removedParticipantIds` gaining an
    /// id that was never present is harmless (it only ever gates future auto-adds of that id, design
    /// section 4.1) and keeps this method idempotent like its counterpart.
    mutating func removeParticipant(_ id: String) {
        participantIds.removeAll { $0 == id }
        guard !removedParticipantIds.contains(id) else { return }
        removedParticipantIds.append(id)
    }
}
