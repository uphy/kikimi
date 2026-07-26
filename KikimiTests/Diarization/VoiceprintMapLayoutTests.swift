import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `VoiceprintMapLayout` (`Kikimi/Diarization/VoiceprintMapLayout.swift`,
/// `docs/design/19-voiceprint-map.md` §8).
///
/// Embeddings here are small (3–4 dims) rather than 256-d — every algorithm under test is
/// dimension-agnostic, and small vectors keep the expected geometry checkable by hand. Fixtures
/// deliberately avoid symmetric configurations (§8: near-degenerate eigenvalue spectra leave the
/// eigenbasis under-determined, which the sign convention cannot fix).
@Suite("VoiceprintMapLayout")
struct VoiceprintMapLayoutTests {
    private func makeSpeaker(
        id: String,
        embedding: [Float],
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> VoiceprintSpeaker {
        VoiceprintSpeaker(
            id: id,
            name: "speaker-\(id)",
            embedding: embedding,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: updatedAt
        )
    }

    /// True embedding-space Euclidean distance² between two speakers after L2 normalization —
    /// the right-hand side of the design §3.1 identity `‖a − b‖² = 2 × cosineDistance`.
    private func trueSquaredDistance(_ a: [Float], _ b: [Float]) -> Double {
        2 * Double(VoiceprintStore.cosineDistance(a, b))
    }

    private func point(
        _ id: String, in points: [VoiceprintMapLayout.SpeakerPoint]
    ) throws -> VoiceprintMapLayout.SpeakerPoint {
        try #require(points.first { $0.speakerId == id })
    }

    private func squaredDistance(
        _ lhs: VoiceprintMapLayout.SpeakerPoint, _ rhs: VoiceprintMapLayout.SpeakerPoint
    ) -> Double {
        (lhs.x - rhs.x) * (lhs.x - rhs.x) + (lhs.y - rhs.y) * (lhs.y - rhs.y)
    }

    // MARK: - compute: identity for ≤ 3 speakers (§8 "恒等式の検証")

    @Test("3 speakers: 2D distances reproduce 2×cosineDistance exactly (rank ≤ 2, no loss)")
    func threeSpeakersPreserveAllPairwiseDistances() throws {
        // Asymmetric on purpose — well-separated eigenvalues.
        let speakers = [
            makeSpeaker(id: "a", embedding: [1, 0, 0, 0]),
            makeSpeaker(id: "b", embedding: [0.8, 0.6, 0, 0]),
            makeSpeaker(id: "c", embedding: [0.5, 0.1, 0.6, 0]),
        ]
        let (points, excluded) = VoiceprintMapLayout.compute(speakers: speakers)
        #expect(excluded.isEmpty)
        #expect(points.count == 3)

        for first in 0..<speakers.count {
            for second in (first + 1)..<speakers.count {
                let expected = trueSquaredDistance(
                    speakers[first].embedding, speakers[second].embedding
                )
                let actual = try squaredDistance(
                    point(speakers[first].id, in: points),
                    point(speakers[second].id, in: points)
                )
                #expect(abs(actual - expected) < 1e-5)
            }
        }
    }

    @Test("2 speakers: 1D layout on y = 0, separated by the true distance (λ₂ clamp, no NaN)")
    func twoSpeakersProduceOneDimensionalLayout() throws {
        let speakers = [
            makeSpeaker(id: "a", embedding: [1, 0, 0, 0]),
            makeSpeaker(id: "b", embedding: [0.6, 0.8, 0, 0]),
        ]
        let (points, excluded) = VoiceprintMapLayout.compute(speakers: speakers)
        #expect(excluded.isEmpty)
        #expect(points.count == 2)
        for mapPoint in points {
            #expect(mapPoint.x.isFinite)
            #expect(mapPoint.y == 0)
        }
        let actual = try squaredDistance(point("a", in: points), point("b", in: points))
        let expected = trueSquaredDistance(speakers[0].embedding, speakers[1].embedding)
        #expect(abs(actual - expected) < 1e-5)
    }

    // MARK: - compute: general invariants for 4+ speakers (§8 "決定論")

    /// 5 asymmetric speakers used by the 4+-point tests below.
    private var fivePointFixture: [VoiceprintSpeaker] {
        [
            makeSpeaker(id: "a", embedding: [1, 0, 0, 0]),
            makeSpeaker(id: "b", embedding: [0.9, 0.4, 0.1, 0]),
            makeSpeaker(id: "c", embedding: [0.2, 1, 0.3, 0.1]),
            makeSpeaker(id: "d", embedding: [0.1, 0.2, 1, 0.4]),
            makeSpeaker(id: "e", embedding: [0.3, 0.1, 0.2, 1]),
        ]
    }

    @Test("projection is non-expansive: 2D distance never exceeds the true distance")
    func projectionNeverExpandsDistances() throws {
        let speakers = fivePointFixture
        let (points, _) = VoiceprintMapLayout.compute(speakers: speakers)
        for first in 0..<speakers.count {
            for second in (first + 1)..<speakers.count {
                let trueValue = trueSquaredDistance(
                    speakers[first].embedding, speakers[second].embedding
                )
                let projected = try squaredDistance(
                    point(speakers[first].id, in: points),
                    point(speakers[second].id, in: points)
                )
                #expect(projected <= trueValue + 1e-5)
            }
        }
    }

    @Test("deterministic: shuffled input produces bit-identical coordinates (canonical ordering)")
    func shuffledInputProducesIdenticalCoordinates() {
        let speakers = fivePointFixture
        let (points, _) = VoiceprintMapLayout.compute(speakers: speakers)
        let (shuffledPoints, _) = VoiceprintMapLayout.compute(speakers: speakers.reversed())
        #expect(points == shuffledPoints)
    }

    @Test("all coordinates are finite and the layout is 2-dimensional for a generic 5-point input")
    func genericLayoutIsFiniteAndSpread() {
        let (points, excluded) = VoiceprintMapLayout.compute(speakers: fivePointFixture)
        #expect(excluded.isEmpty)
        #expect(points.count == 5)
        #expect(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        // A generic (non-collinear) configuration must actually use both axes.
        #expect(points.contains { abs($0.y) > 1e-6 })
    }

    // MARK: - compute: degenerate sizes and exclusions (§8 "縮退")

    @Test("0 speakers -> no points; 1 speaker -> a single finite point")
    func degenerateSizes() {
        let (emptyPoints, emptyExcluded) = VoiceprintMapLayout.compute(speakers: [])
        #expect(emptyPoints.isEmpty)
        #expect(emptyExcluded.isEmpty)

        let single = [makeSpeaker(id: "a", embedding: [1, 0, 0, 0])]
        let (points, excluded) = VoiceprintMapLayout.compute(speakers: single)
        #expect(excluded.isEmpty)
        #expect(points.count == 1)
        #expect(points[0].x.isFinite)
        #expect(points[0].y.isFinite)
    }

    @Test("invalid embeddings are excluded with the design §3.2 reason codes")
    func exclusionReasons() {
        let speakers = [
            makeSpeaker(id: "empty", embedding: []),
            makeSpeaker(id: "nan", embedding: [Float.nan, 0, 0, 0]),
            makeSpeaker(id: "zero", embedding: [0, 0, 0, 0]),
            makeSpeaker(id: "short", embedding: [1, 0, 0]),
            makeSpeaker(id: "ok1", embedding: [1, 0, 0, 0]),
            makeSpeaker(id: "ok2", embedding: [0.8, 0.6, 0, 0]),
        ]
        let (points, excluded) = VoiceprintMapLayout.compute(speakers: speakers)
        #expect(Set(points.map(\.speakerId)) == ["ok1", "ok2"])
        #expect(
            excluded.sorted { $0.speakerId < $1.speakerId } == [
                .init(speakerId: "empty", reason: .empty),
                .init(speakerId: "nan", reason: .nonFinite),
                .init(speakerId: "short", reason: .lengthMismatch),
                .init(speakerId: "zero", reason: .zeroVector),
            ]
        )
    }

    @Test("reference length is the majority length, so one malformed entry can't redefine normal")
    func referenceLengthIsMajority() {
        let speakers = [
            makeSpeaker(id: "a", embedding: [1, 0, 0, 0]),
            makeSpeaker(id: "b", embedding: [0.8, 0.6, 0, 0]),
            makeSpeaker(id: "c", embedding: [0.5, 0.1, 0.6, 0]),
            makeSpeaker(id: "odd", embedding: [1, 0]),
        ]
        let (points, excluded) = VoiceprintMapLayout.compute(speakers: speakers)
        #expect(points.count == 3)
        #expect(excluded == [.init(speakerId: "odd", reason: .lengthMismatch)])
    }

    // MARK: - closePairs (§8: strictly <, Double promotion, no duplicates)

    @Test("closePairs uses strictly-below-threshold semantics, matching VoiceprintMatchPolicy's threshold check")
    func closePairsThresholdBoundary() {
        // Orthogonal vectors: cosine distance exactly 1.0.
        let speakers = [
            makeSpeaker(id: "a", embedding: [1, 0, 0, 0]),
            makeSpeaker(id: "b", embedding: [0, 1, 0, 0]),
        ]
        #expect(VoiceprintMapLayout.closePairs(speakers: speakers, threshold: 1.0).isEmpty)

        let pairs = VoiceprintMapLayout.closePairs(speakers: speakers, threshold: 1.0001)
        #expect(pairs == [.init(firstId: "a", secondId: "b", distance: 1.0)])
    }

    @Test("closePairs returns each qualifying pair once, closest first, firstId < secondId")
    func closePairsOrderingAndUniqueness() {
        let speakers = [
            makeSpeaker(id: "c", embedding: [1, 0, 0, 0]),
            makeSpeaker(id: "a", embedding: [1, 0.01, 0, 0]),   // ~0 distance to "c"
            makeSpeaker(id: "b", embedding: [0.8, 0.6, 0, 0]),  // moderate distance to both
        ]
        let pairs = VoiceprintMapLayout.closePairs(speakers: speakers, threshold: 2.0)
        #expect(pairs.count == 3)
        #expect(pairs[0].firstId == "a")
        #expect(pairs[0].secondId == "c")
        #expect(pairs.allSatisfy { $0.firstId < $0.secondId })
        #expect(pairs == pairs.sorted { $0.distance < $1.distance })
    }

    @Test("close pairs sharing one speaker have distinct ids (SwiftUI ForEach identity)")
    func closePairsSharingASpeakerHaveDistinctIds() {
        // "hub" is under-threshold-close to both others (regression: identifying pairs by
        // firstId alone rendered the A–B banner twice instead of A–B and A–C).
        let speakers = [
            makeSpeaker(id: "hub", embedding: [1, 0, 0, 0]),
            makeSpeaker(id: "near1", embedding: [0.95, 0.3, 0, 0]),
            makeSpeaker(id: "near2", embedding: [0.95, 0, 0.3, 0]),
        ]
        let pairs = VoiceprintMapLayout.closePairs(speakers: speakers, threshold: 0.2)
        #expect(pairs.count >= 2)
        #expect(Set(pairs.map(\.id)).count == pairs.count)
    }

    @Test("closePairs never includes excluded speakers")
    func closePairsSkipsExcludedSpeakers() {
        let speakers = [
            makeSpeaker(id: "a", embedding: [1, 0, 0, 0]),
            makeSpeaker(id: "b", embedding: [1, 0, 0, 0]),
            makeSpeaker(id: "nan", embedding: [Float.nan, 0, 0, 0]),
        ]
        let pairs = VoiceprintMapLayout.closePairs(speakers: speakers, threshold: 0.5)
        #expect(pairs == [.init(firstId: "a", secondId: "b", distance: 0.0)])
    }

    // MARK: - neighbors (§8: KnownSpeakerSort rule, topN, exclusions)

    @Test("neighbors sorts by ascending distance with descending updatedAt tie-break")
    func neighborsSortRule() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let speakers = [
            makeSpeaker(id: "target", embedding: [1, 0, 0, 0]),
            makeSpeaker(id: "far", embedding: [0, 1, 0, 0], updatedAt: newer),
            // "tieOld"/"tieNew" are identical, so they tie in distance to "target".
            makeSpeaker(id: "tieOld", embedding: [0.8, 0.6, 0, 0], updatedAt: older),
            makeSpeaker(id: "tieNew", embedding: [0.8, 0.6, 0, 0], updatedAt: newer),
        ]
        let neighbors = VoiceprintMapLayout.neighbors(of: "target", in: speakers, topN: 3)
        #expect(neighbors.map(\.speakerId) == ["tieNew", "tieOld", "far"])
    }

    @Test("neighbors truncates to topN and returns [] for unknown or excluded targets")
    func neighborsTopNAndInvalidTargets() {
        let speakers = [
            makeSpeaker(id: "target", embedding: [1, 0, 0, 0]),
            makeSpeaker(id: "b", embedding: [0.9, 0.1, 0, 0]),
            makeSpeaker(id: "c", embedding: [0.5, 0.5, 0, 0]),
            makeSpeaker(id: "nan", embedding: [Float.nan, 0, 0, 0]),
        ]
        let top1 = VoiceprintMapLayout.neighbors(of: "target", in: speakers, topN: 1)
        #expect(top1.map(\.speakerId) == ["b"])

        let all = VoiceprintMapLayout.neighbors(of: "target", in: speakers, topN: 10)
        #expect(all.map(\.speakerId) == ["b", "c"])  // "nan" is excluded from the population

        #expect(VoiceprintMapLayout.neighbors(of: "unknown", in: speakers, topN: 3).isEmpty)
        #expect(VoiceprintMapLayout.neighbors(of: "nan", in: speakers, topN: 3).isEmpty)
    }
}
