import Foundation
import Testing

@testable import Kikimi

// MARK: - SessionParticipants

/// Unit tests for `SessionParticipants` (`Kikimi/SessionStore/DiarizationModels.swift`,
/// `docs/design/22-participant-hints.md` section 1.1): the pure Codable model + `addParticipant(_:)`/
/// `removeParticipant(_:)` invariant, independent of `SessionHandle` I/O (covered separately by
/// `SessionHandleDiarizationTests.swift`).
@Suite("SessionParticipants")
struct SessionParticipantsTests {
    // MARK: - Codable round-trip (snake_case)

    @Test("round-trips through the shared SessionJSONCoding encoder/decoder with snake_case keys")
    func roundTripsSnakeCase() throws {
        let original = SessionParticipants(
            participantIds: ["b3f1", "c4a2"],
            removedParticipantIds: ["d5e3"]
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SessionParticipants.self, from: data)

        #expect(decoded == original)

        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"participant_ids\""))
        #expect(text.contains("\"removed_participant_ids\""))
        #expect(!text.contains("participantIds"))
        #expect(!text.contains("removedParticipantIds"))
    }

    @Test("matches design section 1.1's sample JSON shape")
    func decodesDesignSampleJSON() throws {
        let json = """
        {
          "participant_ids": ["b3f1...", "c4a2..."],
          "removed_participant_ids": ["d5e3..."]
        }
        """
        let decoded = try SessionJSONCoding.makeDecoder().decode(SessionParticipants.self, from: Data(json.utf8))
        #expect(decoded.participantIds == ["b3f1...", "c4a2..."])
        #expect(decoded.removedParticipantIds == ["d5e3..."])
    }

    // MARK: - Defensive decode

    @Test("an empty object decodes as an empty roster (no keys present)")
    func emptyObjectDecodesEmpty() throws {
        let decoded = try SessionJSONCoding.makeDecoder().decode(SessionParticipants.self, from: Data("{}".utf8))
        #expect(decoded == SessionParticipants())
        #expect(decoded.participantIds.isEmpty)
        #expect(decoded.removedParticipantIds.isEmpty)
    }

    @Test("a missing removed_participant_ids key decodes as an empty removal list")
    func missingRemovedKeyDecodesEmpty() throws {
        let json = """
        {"participant_ids": ["b3f1"]}
        """
        let decoded = try SessionJSONCoding.makeDecoder().decode(SessionParticipants.self, from: Data(json.utf8))
        #expect(decoded.participantIds == ["b3f1"])
        #expect(decoded.removedParticipantIds.isEmpty)
    }

    @Test("a missing participant_ids key decodes as an empty roster")
    func missingParticipantsKeyDecodesEmpty() throws {
        let json = """
        {"removed_participant_ids": ["d5e3"]}
        """
        let decoded = try SessionJSONCoding.makeDecoder().decode(SessionParticipants.self, from: Data(json.utf8))
        #expect(decoded.participantIds.isEmpty)
        #expect(decoded.removedParticipantIds == ["d5e3"])
    }

    // MARK: - addParticipant / removeParticipant exclusivity invariant

    @Test("addParticipant appends a new id and removes it from removedParticipantIds if present")
    func addParticipantAddsAndUnremoves() {
        var participants = SessionParticipants(removedParticipantIds: ["b3f1"])
        participants.addParticipant("b3f1")

        #expect(participants.participantIds == ["b3f1"])
        #expect(participants.removedParticipantIds.isEmpty)
    }

    @Test("addParticipant is idempotent -- adding an already-present id does not duplicate it")
    func addParticipantIsIdempotent() {
        var participants = SessionParticipants(participantIds: ["b3f1"])
        participants.addParticipant("b3f1")

        #expect(participants.participantIds == ["b3f1"])
    }

    @Test("addParticipant preserves insertion order across multiple adds")
    func addParticipantPreservesOrder() {
        var participants = SessionParticipants()
        participants.addParticipant("b3f1")
        participants.addParticipant("c4a2")

        #expect(participants.participantIds == ["b3f1", "c4a2"])
    }

    @Test("removeParticipant moves an id out of participantIds and into removedParticipantIds")
    func removeParticipantMoves() {
        var participants = SessionParticipants(participantIds: ["b3f1", "c4a2"])
        participants.removeParticipant("b3f1")

        #expect(participants.participantIds == ["c4a2"])
        #expect(participants.removedParticipantIds == ["b3f1"])
    }

    @Test("removeParticipant is idempotent -- removing an already-removed id does not duplicate it")
    func removeParticipantIsIdempotent() {
        var participants = SessionParticipants(removedParticipantIds: ["b3f1"])
        participants.removeParticipant("b3f1")

        #expect(participants.removedParticipantIds == ["b3f1"])
    }

    @Test("the two lists never contain the same id at the same time, across repeated add/remove cycles")
    func listsStayMutuallyExclusive() {
        var participants = SessionParticipants()

        participants.addParticipant("b3f1")
        #expect(Set(participants.participantIds).isDisjoint(with: Set(participants.removedParticipantIds)))

        participants.removeParticipant("b3f1")
        #expect(Set(participants.participantIds).isDisjoint(with: Set(participants.removedParticipantIds)))

        participants.addParticipant("b3f1")
        #expect(Set(participants.participantIds).isDisjoint(with: Set(participants.removedParticipantIds)))
        #expect(participants.participantIds == ["b3f1"])
        #expect(participants.removedParticipantIds.isEmpty)
    }
}
