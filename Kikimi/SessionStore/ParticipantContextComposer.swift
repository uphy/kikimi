import Foundation

// MARK: - ParticipantContextComposer

/// Injects the session's participant roster into the LLM context text embedded in refinement/summary
/// prompts (`docs/design/22-participant-hints.md` §9). Pure by construction -- no `SessionHandle`/
/// `VoiceprintStore` access here -- so both `compose(context:participantNames:)` and
/// `resolveParticipantNames(participantIds:in:)` are directly unit-testable, and the two call sites
/// (`RefinementQueue`'s `context.md` reload, `SummaryUpdater`'s `readContext()` call) only need to
/// fetch `SessionParticipants`/`[VoiceprintSpeaker]` and hand them here.
enum ParticipantContextComposer {
    /// Appends a "【参加者】" block (design §9) listing `participantNames` to `context`, or returns
    /// `context` unchanged if there are no names to inject (design §9: "名簿が空、または名前が 1 件も解決
    /// できない場合はブロックを付けない（完全に従来挙動）" -- this is what keeps a session with no roster
    /// byte-for-byte identical to pre-§9 behavior).
    ///
    /// When `context` is non-empty, one blank line separates it from the block (design §9: "context
    /// 末尾に空行を挟んで... ブロックを連結"); when `context` is empty, the block is returned alone (no
    /// leading blank line).
    static func compose(context: String, participantNames: [String]) -> String {
        guard !participantNames.isEmpty else { return context }
        let block = "【参加者】\n" + participantNames.joined(separator: "、")
        guard !context.isEmpty else { return block }
        return context + "\n\n" + block
    }

    /// Resolves `participantIds` (`SessionParticipants.participantIds`, roster order) to display
    /// names via `speakers` (typically `VoiceprintStore.listSpeakers()`), preserving roster order and
    /// silently skipping any id no longer present among `speakers` (design §9: "解決できない id（DB から
    /// 削除済み）はスキップ"). `removed_participant_ids` is never passed in here -- callers only ever
    /// resolve `participantIds`, matching design §9's "`removed_participant_ids` は含めない".
    static func resolveParticipantNames(participantIds: [String], in speakers: [VoiceprintSpeaker]) -> [String] {
        // Last-wins on a duplicate id, mirroring `[RefinedSegment].indexedBySourceSegId()`'s
        // `uniquingKeysWith:` idiom (`Kikimi/SessionStore/SessionModels.swift`) -- defensive against a
        // corrupt `voiceprints.json` with duplicate ids rather than a scenario expected in practice.
        let namesById = Dictionary(speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
        return participantIds.compactMap { namesById[$0] }
    }
}
