import Foundation
import Testing

@testable import Kikimi

// MARK: - ParticipantContextComposer

/// Unit tests for `ParticipantContextComposer` (`Kikimi/SessionStore/ParticipantContextComposer.swift`,
/// `docs/design/22-participant-hints.md` §9): the pure `compose(context:participantNames:)`/
/// `resolveParticipantNames(participantIds:in:)` functions, independent of `RefinementQueue`/
/// `SummaryUpdater` wiring (covered separately by their own test suites).
@Suite("ParticipantContextComposer")
struct ParticipantContextComposerTests {
    // MARK: - compose(context:participantNames:)

    @Test("empty participant names return context verbatim (identity with pre-§9 behavior)")
    func composeWithNoNamesIsIdentity() {
        #expect(ParticipantContextComposer.compose(context: "アジェンダ: 進捗確認", participantNames: []) == "アジェンダ: 進捗確認")
        #expect(ParticipantContextComposer.compose(context: "", participantNames: []).isEmpty)
    }

    @Test("non-empty names append a blank-line-separated 【参加者】 block, comma-joined in order")
    func composeWithNamesAppendsBlock() {
        let result = ParticipantContextComposer.compose(context: "アジェンダ: 進捗確認", participantNames: ["田中さん", "佐藤さん"])
        #expect(result == "アジェンダ: 進捗確認\n\n【参加者】\n田中さん、佐藤さん")
    }

    @Test("empty context with non-empty names returns the block alone, with no leading blank line")
    func composeWithEmptyContextReturnsBlockOnly() {
        let result = ParticipantContextComposer.compose(context: "", participantNames: ["田中さん"])
        #expect(result == "【参加者】\n田中さん")
    }

    @Test("preserves the order of participantNames as given (roster order)")
    func composePreservesNameOrder() {
        let result = ParticipantContextComposer.compose(context: "", participantNames: ["佐藤さん", "田中さん", "鈴木さん"])
        #expect(result == "【参加者】\n佐藤さん、田中さん、鈴木さん")
    }

    // MARK: - resolveParticipantNames(participantIds:in:)

    private func makeSpeaker(id: String, name: String) -> VoiceprintSpeaker {
        VoiceprintSpeaker(id: id, name: name, embedding: [], createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("empty participantIds resolves to an empty name list")
    func resolveEmptyIdsReturnsEmpty() {
        let speakers = [makeSpeaker(id: "a", name: "田中さん")]
        #expect(ParticipantContextComposer.resolveParticipantNames(participantIds: [], in: speakers).isEmpty)
    }

    @Test("resolves ids to names, preserving roster order (not the speakers array's order)")
    func resolvePreservesRosterOrder() {
        let speakers = [makeSpeaker(id: "a", name: "田中さん"), makeSpeaker(id: "b", name: "佐藤さん")]
        let resolved = ParticipantContextComposer.resolveParticipantNames(participantIds: ["b", "a"], in: speakers)
        #expect(resolved == ["佐藤さん", "田中さん"])
    }

    @Test("skips ids with no matching speaker (deleted from the voiceprint database)")
    func resolveSkipsUnknownIds() {
        let speakers = [makeSpeaker(id: "a", name: "田中さん")]
        let resolved = ParticipantContextComposer.resolveParticipantNames(participantIds: ["a", "missing", "a"], in: speakers)
        #expect(resolved == ["田中さん", "田中さん"])
    }

    @Test("no speakers at all resolves every id to nothing")
    func resolveWithNoSpeakersReturnsEmpty() {
        #expect(ParticipantContextComposer.resolveParticipantNames(participantIds: ["a", "b"], in: []).isEmpty)
    }
}
