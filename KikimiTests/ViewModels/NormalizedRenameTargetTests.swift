import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `NormalizedRenameTarget.resolve(name:knownSpeakers:)`
/// (`Kikimi/ViewModels/NormalizedRenameTarget.swift`,
/// `docs/design/20-voiceprint-misassignment-mitigation.md` section 4). Pure/deterministic (no I/O), so
/// every branch is exercised directly here without a `VoiceprintStore`/`SessionHandle` round-trip.
@Suite("NormalizedRenameTarget.resolve")
struct NormalizedRenameTargetTests {
    private static func speaker(id: String, name: String) -> VoiceprintSpeaker {
        VoiceprintSpeaker(
            id: id,
            name: name,
            embedding: [0.1, 0.2],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("a name matching exactly one known speaker resolves to .existing with that speaker's id/name")
    func exactlyOneMatchResolvesToExisting() {
        let tanaka = Self.speaker(id: "g1", name: "田中さん")
        let sato = Self.speaker(id: "g2", name: "佐藤さん")

        let result = NormalizedRenameTarget.resolve(name: "田中さん", knownSpeakers: [tanaka, sato])

        #expect(result == .existing(globalSpeakerId: "g1", name: "田中さん"))
    }

    @Test("a name matching none of the known speakers resolves to .new")
    func noMatchResolvesToNew() {
        let sato = Self.speaker(id: "g2", name: "佐藤さん")

        let result = NormalizedRenameTarget.resolve(name: "鈴木さん", knownSpeakers: [sato])

        #expect(result == .new("鈴木さん"))
    }

    @Test("an empty known-speaker list always resolves to .new")
    func emptyKnownSpeakersResolvesToNew() {
        let result = NormalizedRenameTarget.resolve(name: "田中さん", knownSpeakers: [])
        #expect(result == .new("田中さん"))
    }

    @Test("a name matching more than one known speaker (a same-name duplicate) resolves to .ambiguous")
    func multipleMatchesResolveToAmbiguous() {
        let tanaka1 = Self.speaker(id: "g1", name: "田中さん")
        let tanaka2 = Self.speaker(id: "g2", name: "田中さん")

        let result = NormalizedRenameTarget.resolve(name: "田中さん", knownSpeakers: [tanaka1, tanaka2])

        #expect(result == .ambiguous("田中さん"))
    }

    @Test("leading/trailing whitespace in the typed name is trimmed before comparing")
    func trimsWhitespaceInTypedName() {
        let tanaka = Self.speaker(id: "g1", name: "田中さん")

        let result = NormalizedRenameTarget.resolve(name: "  田中さん  ", knownSpeakers: [tanaka])

        #expect(result == .existing(globalSpeakerId: "g1", name: "田中さん"))
    }

    @Test("leading/trailing whitespace in a known speaker's stored name is also trimmed before comparing, but the returned name is that speaker's canonical stored name, unmodified")
    func trimsWhitespaceInKnownSpeakerNameForComparisonOnly() {
        let tanaka = Self.speaker(id: "g1", name: "  田中さん  ")

        let result = NormalizedRenameTarget.resolve(name: "田中さん", knownSpeakers: [tanaka])

        // The match succeeds (comparison is trimmed on both sides), but the `name` this returns is
        // `VoiceprintSpeaker.name` verbatim -- normalization's trimming is only ever a comparison
        // detail, not a rewrite of the registered speaker's canonical name.
        #expect(result == .existing(globalSpeakerId: "g1", name: "  田中さん  "))
    }

    @Test("a whitespace-only typed name still resolves against the trimmed (empty) comparison")
    func whitespaceOnlyNameTrimsToEmpty() {
        let result = NormalizedRenameTarget.resolve(name: "   ", knownSpeakers: [])
        #expect(result == .new(""))
    }
}
