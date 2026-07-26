import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `VoiceprintStore` (`Kikimi/Diarization/VoiceprintStore.swift`,
/// `docs/design/13-speaker-diarization.md` section 4.4: the global cross-session voiceprint DB).
///
/// Every test constructs its own `VoiceprintStore(fileURL:)` pointing at a fresh temporary file so
/// none of them touch `~/.local/state/kikimi/voiceprints.json` or interfere with each other.
@Suite("VoiceprintStore")
struct VoiceprintStoreTests {
    /// A temporary file path (not yet created) under a unique subdirectory, so parallel test runs
    /// never collide.
    private func makeTempFileURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceprintStoreTests-\(UUID().uuidString)", isDirectory: true)
        return directory.appendingPathComponent("voiceprints.json")
    }

    private func makeEmbedding(_ values: [Float]) -> [Float] {
        values
    }

    /// Reproduces the former `VoiceprintStore.findBestMatch(embedding:threshold:)`'s "closest speaker
    /// under threshold, else nil" contract on top of the new `findMatchCandidate(embedding:)` +
    /// `VoiceprintMatchPolicy.decide(candidate:threshold:margin:)` split (design section 20 §3.1): with
    /// `margin: 0`, `VoiceprintMatchPolicy` never rejects on margin (its doc comment: "reproducing the
    /// former `findBestMatch`'s margin-unaware ... behavior exactly"), so this is exactly the old
    /// behavior for every test below that doesn't care about the margin.
    private func bestMatch(
        store: VoiceprintStore, embedding: [Float], threshold: Double, margin: Double = 0
    ) async -> VoiceprintSpeaker? {
        guard let candidate = await store.findMatchCandidate(embedding: embedding) else { return nil }
        let decision = VoiceprintMatchPolicy.decide(candidate: candidate, threshold: threshold, margin: margin)
        return decision == .accepted ? candidate.speaker : nil
    }

    // MARK: - Round-trip

    @Test("a registered speaker survives a save + fresh-instance reload")
    func roundTrip() async throws {
        let url = makeTempFileURL()
        let store = VoiceprintStore(fileURL: url)

        let created = Date(timeIntervalSince1970: 1_000)
        let registered = try await store.registerSpeaker(
            name: "田中さん", embedding: makeEmbedding([1, 0, 0]), now: created
        )

        #expect(FileManager.default.fileExists(atPath: url.path))

        // A brand-new instance pointed at the same file must see exactly what was persisted, not
        // rely on in-memory state carried over from `store`.
        let reloaded = VoiceprintStore(fileURL: url)
        let speakers = await reloaded.listSpeakers()

        #expect(speakers == [registered])
        #expect(speakers.first?.name == "田中さん")
        #expect(speakers.first?.embedding == [1, 0, 0])
        #expect(speakers.first?.createdAt == created)
        #expect(speakers.first?.updatedAt == created)
        #expect(speakers.first?.lastMatchedSessionId == nil)
    }

    @Test("rename persists across a fresh-instance reload and never touches the embedding")
    func renamePersists() async throws {
        let url = makeTempFileURL()
        let store = VoiceprintStore(fileURL: url)
        let registered = try await store.registerSpeaker(name: "Speaker 1", embedding: [1, 0, 0])

        try await store.renameSpeaker(id: registered.id, name: "佐藤さん")

        let reloaded = VoiceprintStore(fileURL: url)
        let speaker = await reloaded.speaker(id: registered.id)
        #expect(speaker?.name == "佐藤さん")
        #expect(speaker?.embedding == [1, 0, 0])
    }

    @Test("delete removes the speaker and persists")
    func deletePersists() async throws {
        let url = makeTempFileURL()
        let store = VoiceprintStore(fileURL: url)
        let registered = try await store.registerSpeaker(name: "Speaker 1", embedding: [1, 0, 0])

        try await store.deleteSpeaker(id: registered.id)
        #expect(await store.listSpeakers().isEmpty)

        let reloaded = VoiceprintStore(fileURL: url)
        #expect(await reloaded.listSpeakers().isEmpty)
    }

    // MARK: - Registration with an empty embedding (`docs/design/22-participant-hints.md` section 1/4.1's
    // suggest-box "space it out" registration path: a brand-new participant hint with no voice sample yet)

    @Test("registerSpeaker with an empty embedding succeeds, persists, and appears in listSpeakers")
    func registerSpeakerWithEmptyEmbeddingSucceeds() async throws {
        let url = makeTempFileURL()
        let store = VoiceprintStore(fileURL: url)

        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [])
        #expect(registered.embedding.isEmpty)

        let reloaded = VoiceprintStore(fileURL: url)
        let speakers = await reloaded.listSpeakers()
        #expect(speakers.map(\.id) == [registered.id])
        #expect(speakers.first?.name == "田中さん")
    }

    @Test("a speaker registered with an empty embedding never appears as a findMatchCandidate result")
    func registerSpeakerWithEmptyEmbeddingNeverMatches() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        try await store.registerSpeaker(name: "田中さん", embedding: [])

        let candidate = await store.findMatchCandidate(embedding: [1, 0, 0])
        #expect(candidate == nil, "an empty embedding must make cosineDistance .infinity, excluding it from matching entirely")
    }

    @Test("a speaker registered with an empty embedding never appears as a runner-up either")
    func registerSpeakerWithEmptyEmbeddingNeverActsAsRunnerUp() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        try await store.registerSpeaker(name: "空の声紋さん", embedding: [])
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])

        let candidate = try #require(await store.findMatchCandidate(embedding: [1, 0, 0]))
        #expect(candidate.speaker.id == registered.id)
        #expect(candidate.runnerUp == nil)
    }

    // MARK: - Corruption fallback

    @Test("a missing file starts as an empty DB (not a failure)")
    func missingFileIsEmptyDatabase() async {
        let url = makeTempFileURL()
        let store = VoiceprintStore(fileURL: url)
        #expect(await store.listSpeakers().isEmpty)
    }

    @Test("a corrupt/unreadable file falls back to an empty DB rather than throwing")
    func corruptFileFallsBackToEmptyDatabase() async throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{ this is not valid json".utf8).write(to: url)

        let store = VoiceprintStore(fileURL: url)
        #expect(await store.listSpeakers().isEmpty)

        // The store must still be fully usable afterward (design section 8: corruption only degrades
        // matching, it never blocks the rest of the app), including overwriting the corrupt file.
        try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        #expect(await store.listSpeakers().count == 1)
    }

    @Test("an empty database's speakers array decodes fine on top-level key absence")
    func missingSpeakersKeyDecodesEmpty() throws {
        let decoder = SessionJSONCoding.makeDecoder()
        let db = try decoder.decode(VoiceprintDatabase.self, from: Data("{}".utf8))
        #expect(db.speakers.isEmpty)
    }

    // MARK: - Actor serialization / concurrent access

    @Test("many concurrent registrations are all persisted without loss (actor serializes writes)")
    func concurrentRegistrationsAllPersist() async throws {
        let url = makeTempFileURL()
        let store = VoiceprintStore(fileURL: url)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await store.registerSpeaker(name: "Speaker \(index)", embedding: [Float(index), 0, 0])
                }
            }
            try await group.waitForAll()
        }

        let speakers = await store.listSpeakers()
        #expect(speakers.count == 20)
        #expect(Set(speakers.map(\.id)).count == 20)

        // Reload from disk to make sure the final persisted file reflects every write, not just the
        // in-memory actor state.
        let reloaded = VoiceprintStore(fileURL: url)
        #expect(await reloaded.listSpeakers().count == 20)
    }

    // MARK: - Match threshold boundaries

    @Test("an empty database's match always returns nil")
    func emptyDatabaseMatchReturnsNil() async {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let match = await bestMatch(store: store, embedding: [1, 0, 0], threshold: 0.65)
        #expect(match == nil)
    }

    @Test("distance strictly below threshold matches; distance exactly at threshold does not (design: distance < threshold)")
    func thresholdBoundaryIsStrictlyLessThan() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let stored: [Float] = [1, 0]
        let probe: [Float] = [0.6, 0.8]
        // Derive the exact (deterministic) distance the store's own comparison will compute, rather
        // than a hand-picked constant that risks floating-point drift against a trig-derived probe —
        // recomputing `cosineDistance` here with the identical inputs gives bit-for-bit the same value.
        let distance = Double(VoiceprintStore.cosineDistance(stored, probe))
        try await store.registerSpeaker(name: "田中さん", embedding: stored)

        let matchAtThreshold = await bestMatch(store: store, embedding: probe, threshold: distance)
        #expect(matchAtThreshold == nil)

        let matchJustAboveThreshold = await bestMatch(store: store, embedding: probe, threshold: distance + 0.0001)
        #expect(matchJustAboveThreshold?.name == "田中さん")
    }

    @Test("the closest of several under-threshold candidates wins")
    func closestCandidateWins() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        try await store.registerSpeaker(name: "far", embedding: [1, 0.3])
        try await store.registerSpeaker(name: "near", embedding: [1, 0.01])

        let match = await bestMatch(store: store, embedding: [1, 0], threshold: 0.9)
        #expect(match?.name == "near")
    }

    @Test("identical vectors have zero distance and always match a positive threshold")
    func identicalVectorsMatch() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        try await store.registerSpeaker(name: "田中さん", embedding: [0.6, 0.8])

        let match = await bestMatch(store: store, embedding: [0.6, 0.8], threshold: 0.01)
        #expect(match?.name == "田中さん")
    }

    @Test("cosineDistance is nil-safe against length mismatch and empty vectors")
    func cosineDistanceGuardsAgainstInvalidInput() {
        #expect(VoiceprintStore.cosineDistance([], []) == .infinity)
        #expect(VoiceprintStore.cosineDistance([1, 0], [1, 0, 0]) == .infinity)
        #expect(VoiceprintStore.cosineDistance([0, 0], [1, 0]) == .infinity)
    }

    // MARK: - Moving-average update

    @Test("moving-average update applies (1-α)*old + α*new and updates lastMatchedSessionId")
    func movingAverageAppliesArithmetic() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1.0, 0.0])
        let now = Date(timeIntervalSince1970: 5_000)

        let applied = try await store.applyMovingAverageUpdate(
            speakerId: registered.id,
            newEmbedding: [0.0, 1.0],
            sessionId: "session-a",
            alpha: 0.1,
            now: now
        )

        #expect(applied)
        let updated = await store.speaker(id: registered.id)
        // (1 - 0.1) * 1.0 + 0.1 * 0.0 == 0.9 ; (1 - 0.1) * 0.0 + 0.1 * 1.0 == 0.1
        #expect(updated?.embedding[0] ?? -1 == Float(0.9))
        #expect(updated?.embedding[1] ?? -1 == Float(0.1))
        #expect(updated?.lastMatchedSessionId == "session-a")
        #expect(updated?.updatedAt == now)
    }

    @Test("a second call from the same session is a dedup no-op")
    func movingAverageDedupGuardSameSession() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1.0, 0.0])

        let firstApplied = try await store.applyMovingAverageUpdate(
            speakerId: registered.id, newEmbedding: [0.0, 1.0], sessionId: "session-a"
        )
        #expect(firstApplied)
        let afterFirst = await store.speaker(id: registered.id)

        let secondApplied = try await store.applyMovingAverageUpdate(
            speakerId: registered.id, newEmbedding: [0.5, 0.5], sessionId: "session-a"
        )
        #expect(!secondApplied)

        // Embedding must be untouched by the skipped second call.
        let afterSecond = await store.speaker(id: registered.id)
        #expect(afterSecond?.embedding == afterFirst?.embedding)
    }

    @Test("a later call from a different session is applied (not blocked by the dedup guard)")
    func movingAverageAppliesForANewSession() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1.0, 0.0])

        _ = try await store.applyMovingAverageUpdate(
            speakerId: registered.id, newEmbedding: [0.0, 1.0], sessionId: "session-a"
        )
        let secondApplied = try await store.applyMovingAverageUpdate(
            speakerId: registered.id, newEmbedding: [0.0, 1.0], sessionId: "session-b"
        )

        #expect(secondApplied)
        let updated = await store.speaker(id: registered.id)
        #expect(updated?.lastMatchedSessionId == "session-b")
    }

    @Test("moving-average update on an unknown speaker id is a no-op, not a throw")
    func movingAverageUnknownSpeakerIsNoOp() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let applied = try await store.applyMovingAverageUpdate(
            speakerId: "does-not-exist", newEmbedding: [1, 0], sessionId: "session-a"
        )
        #expect(!applied)
    }

    @Test("moving-average update with a mismatched embedding length is a no-op, not a throw")
    func movingAverageLengthMismatchIsNoOp() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])

        let applied = try await store.applyMovingAverageUpdate(
            speakerId: registered.id, newEmbedding: [1, 0], sessionId: "session-a"
        )
        #expect(!applied)
        let unchanged = await store.speaker(id: registered.id)
        #expect(unchanged?.embedding == [1, 0, 0])
        #expect(unchanged?.lastMatchedSessionId == nil)
    }

    // MARK: - Persist-failure rollback (regression: a poisoned in-memory entry must not permanently
    // wedge every future save, since `persist()` re-encodes the whole `speakers` array every call)

    @Test("registerSpeaker with a NaN-containing embedding throws (JSONEncoder's default nonConformingFloatEncodingStrategy is .throw), and rolls the in-memory database back instead of leaving the poisoned entry to wedge every future persist")
    func registerSpeakerWithNaNEmbeddingThrowsAndRollsBack() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())

        await #expect(throws: (any Error).self) {
            try await store.registerSpeaker(name: "poisoned", embedding: [Float.nan, 0, 0])
        }

        // The failed registration must not have stuck around in memory.
        #expect(await store.listSpeakers().isEmpty)

        // A subsequent, healthy registration must succeed -- proof the store was not wedged by the
        // earlier failure (without the rollback, this `persist()` would re-encode the still-poisoned
        // NaN entry alongside this new one and throw again).
        let recovered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        let speakers = await store.listSpeakers()
        #expect(speakers == [recovered])
    }

    @Test("applyMovingAverageUpdate producing a NaN result (a NaN newEmbedding component) throws and rolls back, leaving the previously-healthy stored embedding untouched and future persists unaffected")
    func movingAverageUpdateWithNaNResultThrowsAndRollsBack() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])

        await #expect(throws: (any Error).self) {
            try await store.applyMovingAverageUpdate(
                speakerId: registered.id,
                newEmbedding: [Float.nan, 0, 0],
                sessionId: "session-a"
            )
        }

        // The stored embedding/lastMatchedSessionId must be exactly as they were before the failed
        // update, not the poisoned (partially-applied) in-memory value.
        let unchanged = await store.speaker(id: registered.id)
        #expect(unchanged?.embedding == [1, 0, 0])
        #expect(unchanged?.lastMatchedSessionId == nil)

        // A later, healthy write must still succeed.
        try await store.renameSpeaker(id: registered.id, name: "佐藤さん")
        #expect(await store.speaker(id: registered.id)?.name == "佐藤さん")
    }

    // MARK: - Reset (design section 4.4 "声紋リセット")

    @Test("resetSpeakerEmbedding clears embedding/lastMatchedSessionId, updates updatedAt, and persists")
    func resetClearsEmbeddingAndPersists() async throws {
        let url = makeTempFileURL()
        let store = VoiceprintStore(fileURL: url)
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        _ = try await store.applyMovingAverageUpdate(
            speakerId: registered.id, newEmbedding: [0, 1, 0], sessionId: "session-a"
        )

        let resetAt = Date(timeIntervalSince1970: 10_000)
        try await store.resetSpeakerEmbedding(id: registered.id, now: resetAt)

        // Assert against a fresh-instance reload, not just the in-memory actor state, to prove the
        // reset actually persisted (same convention as `roundTrip`).
        let reloaded = VoiceprintStore(fileURL: url)
        let speaker = await reloaded.speaker(id: registered.id)
        #expect(speaker?.embedding == [])
        #expect(speaker?.lastMatchedSessionId == nil)
        #expect(speaker?.updatedAt == resetAt)
        #expect(speaker?.name == "田中さん")
    }

    @Test("a reset speaker never matches bestMatch, no matter the threshold")
    func resetSpeakerNeverMatches() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        try await store.resetSpeakerEmbedding(id: registered.id)

        let match = await bestMatch(store: store, embedding: [1, 0, 0], threshold: 1.0)
        #expect(match == nil)
    }

    @Test("resetSpeakerEmbedding on an unknown id is a no-op, not a throw, and leaves other speakers untouched")
    func resetUnknownIdIsNoOp() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])

        try await store.resetSpeakerEmbedding(id: "does-not-exist")

        let unchanged = await store.speaker(id: registered.id)
        #expect(unchanged?.embedding == [1, 0, 0])
    }

    // MARK: - Re-enrollment after reset (design section 4.4)

    @Test("applyMovingAverageUpdate after a reset adopts the new embedding wholesale (α = 1.0)")
    func movingAverageReEnrollsAfterReset() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        try await store.resetSpeakerEmbedding(id: registered.id)

        let applied = try await store.applyMovingAverageUpdate(
            speakerId: registered.id, newEmbedding: [0.2, 0.4, 0.6], sessionId: "session-b"
        )

        #expect(applied)
        let updated = await store.speaker(id: registered.id)
        #expect(updated?.embedding == [0.2, 0.4, 0.6])
        #expect(updated?.lastMatchedSessionId == "session-b")
    }

    @Test("applyMovingAverageUpdate with an empty newEmbedding is still skipped after a reset")
    func movingAverageEmptyNewEmbeddingSkippedAfterReset() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        try await store.resetSpeakerEmbedding(id: registered.id)

        let applied = try await store.applyMovingAverageUpdate(
            speakerId: registered.id, newEmbedding: [], sessionId: "session-b"
        )

        #expect(!applied)
        let unchanged = await store.speaker(id: registered.id)
        #expect(unchanged?.embedding == [])
        #expect(unchanged?.lastMatchedSessionId == nil)
    }

    // MARK: - findMatchCandidate (design section 20 §3.1/3.2)

    @Test("findMatchCandidate returns nil for an empty database")
    func findMatchCandidateEmptyDatabaseReturnsNil() async {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let candidate = await store.findMatchCandidate(embedding: [1, 0, 0])
        #expect(candidate == nil)
    }

    @Test("findMatchCandidate with a single registered speaker has no runner-up")
    func findMatchCandidateSingleSpeakerHasNoRunnerUp() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])

        let candidate = try #require(await store.findMatchCandidate(embedding: [1, 0, 0]))
        #expect(candidate.speaker.id == registered.id)
        #expect(candidate.runnerUp == nil)
    }

    @Test("findMatchCandidate with several differently-named speakers picks the nearest as the runner-up")
    func findMatchCandidateMultipleSpeakersPicksNearestRunnerUp() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        try await store.registerSpeaker(name: "near", embedding: [1, 0.01])
        try await store.registerSpeaker(name: "far", embedding: [1, 0.3])

        let candidate = try #require(await store.findMatchCandidate(embedding: [1, 0]))
        #expect(candidate.speaker.name == "near")
        #expect(candidate.runnerUp?.name == "far")
        let expectedRunnerUpDistance = VoiceprintStore.cosineDistance([1, 0], [1, 0.3])
        #expect(candidate.runnerUp?.distance == expectedRunnerUpDistance)
    }

    @Test("findMatchCandidate never treats a same-(trimmed)-name duplicate registration as the runner-up (design section 3.1/3.2)")
    func findMatchCandidateSameNameDuplicateIsNotRunnerUp() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        // Two registrations for the same person ("田中さん"), one very close to the probe and one
        // farther away, plus a genuinely different person even farther still.
        try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        try await store.registerSpeaker(name: " 田中さん ", embedding: [1, 0.05, 0])
        try await store.registerSpeaker(name: "佐藤さん", embedding: [1, 0.5, 0])

        let candidate = try #require(await store.findMatchCandidate(embedding: [1, 0, 0]))
        #expect(candidate.speaker.name == "田中さん")
        // The runner-up must skip the duplicate "田中さん" entry (trimmed-name match) and land on the
        // only differently-named speaker, never producing a tiny (near-zero) margin gap against the
        // duplicate that would otherwise cause a correct match to be rejected by margin.
        #expect(candidate.runnerUp?.name == "佐藤さん")
        let expectedRunnerUpDistance = VoiceprintStore.cosineDistance([1, 0, 0], [1, 0.5, 0])
        #expect(candidate.runnerUp?.distance == expectedRunnerUpDistance)
    }

    @Test("findMatchCandidate's runnerUp is nil when every registered speaker shares the same (trimmed) name")
    func findMatchCandidateAllSameNameHasNilRunnerUp() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        try await store.registerSpeaker(name: "田中さん", embedding: [1, 0.2, 0])

        let candidate = try #require(await store.findMatchCandidate(embedding: [1, 0, 0]))
        #expect(candidate.runnerUp == nil)
    }

    @Test("findMatchCandidate excludes a reset (empty-embedding) speaker from both nearest and runner-up")
    func findMatchCandidateExcludesResetSpeaker() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let resetTarget = try await store.registerSpeaker(name: "reset-me", embedding: [1, 0, 0])
        try await store.resetSpeakerEmbedding(id: resetTarget.id)
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [0, 1, 0])

        let candidate = try #require(await store.findMatchCandidate(embedding: [0, 1, 0]))
        #expect(candidate.speaker.id == registered.id, "the reset speaker must never be selected as nearest")
        #expect(candidate.runnerUp == nil, "the reset speaker must never be selected as runner-up either")
    }

    // MARK: - findMatchCandidate(allowedSpeakerIds:) (`docs/design/22-participant-hints.md` section 2.1)

    @Test("allowedSpeakerIds: nil reproduces the exact open-set behavior (regression guard)")
    func findMatchCandidateNilAllowedSpeakerIdsIsOpenSet() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        try await store.registerSpeaker(name: "near", embedding: [1, 0.01])
        try await store.registerSpeaker(name: "far", embedding: [1, 0.3])

        let withoutFilter = await store.findMatchCandidate(embedding: [1, 0])
        let withNilFilter = await store.findMatchCandidate(embedding: [1, 0], allowedSpeakerIds: nil)

        #expect(withoutFilter?.speaker.name == "near")
        #expect(withNilFilter == withoutFilter)
    }

    @Test("allowedSpeakerIds excludes an off-roster nearest speaker, letting an on-roster next-best win")
    func findMatchCandidateFiltersToRosterNearest() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let nearestOffRoster = try await store.registerSpeaker(name: "near", embedding: [1, 0.01])
        let nextBestOnRoster = try await store.registerSpeaker(name: "far", embedding: [1, 0.3])

        let unfiltered = try #require(await store.findMatchCandidate(embedding: [1, 0]))
        #expect(unfiltered.speaker.id == nearestOffRoster.id, "sanity check: without a roster, the true nearest wins")

        let filtered = try #require(
            await store.findMatchCandidate(embedding: [1, 0], allowedSpeakerIds: [nextBestOnRoster.id])
        )
        #expect(filtered.speaker.id == nextBestOnRoster.id, "the off-roster nearest speaker must never be selected")
    }

    @Test("allowedSpeakerIds restricts the runner-up to roster members too, not just the nearest match")
    func findMatchCandidateFiltersRunnerUpToRoster() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let onRosterNearest = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0])
        // Off-roster, closer to the nearest match than any on-roster runner-up would be -- if this were
        // still allowed to act as the runner-up, its tiny margin gap would wrongly reject the match.
        try await store.registerSpeaker(name: "佐藤さん", embedding: [1, 0.001])
        let onRosterRunnerUp = try await store.registerSpeaker(name: "鈴木さん", embedding: [1, 0.5])

        let candidate = try #require(
            await store.findMatchCandidate(
                embedding: [1, 0], allowedSpeakerIds: [onRosterNearest.id, onRosterRunnerUp.id]
            )
        )
        #expect(candidate.speaker.id == onRosterNearest.id)
        #expect(candidate.runnerUp?.name == "鈴木さん", "the off-roster near-duplicate must never act as the runner-up")
    }

    @Test("an empty allowedSpeakerIds set is treated defensively as \"no candidates\" (nil, not open-set)")
    func findMatchCandidateEmptyAllowedSpeakerIdsReturnsNil() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])

        let candidate = await store.findMatchCandidate(embedding: [1, 0, 0], allowedSpeakerIds: [])
        #expect(candidate == nil)
    }

    @Test("allowedSpeakerIds combined with an empty-embedding (reset) speaker still excludes that speaker")
    func findMatchCandidateRosterFilterAndEmptyEmbeddingExclusionCompose() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let resetOnRoster = try await store.registerSpeaker(name: "reset-me", embedding: [1, 0, 0])
        try await store.resetSpeakerEmbedding(id: resetOnRoster.id)
        let healthyOnRoster = try await store.registerSpeaker(name: "田中さん", embedding: [0, 1, 0])

        let candidate = try #require(
            await store.findMatchCandidate(
                embedding: [0, 1, 0], allowedSpeakerIds: [resetOnRoster.id, healthyOnRoster.id]
            )
        )
        #expect(candidate.speaker.id == healthyOnRoster.id, "a reset speaker must stay excluded even when on the roster")
    }

    @Test("allowedSpeakerIds containing an id with no registered speaker simply has no effect for that id")
    func findMatchCandidateAllowedSpeakerIdsToleratesUnknownIds() async throws {
        let store = VoiceprintStore(fileURL: makeTempFileURL())
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])

        let candidate = try #require(
            await store.findMatchCandidate(embedding: [1, 0, 0], allowedSpeakerIds: [registered.id, "unknown-id"])
        )
        #expect(candidate.speaker.id == registered.id)
    }
}
