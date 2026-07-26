import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `VoiceprintMatchPolicy` (`Kikimi/Diarization/VoiceprintMatchPolicy.swift`,
/// `docs/design/20-voiceprint-misassignment-mitigation.md` section 3.1). Every test builds its
/// `VoiceprintStore.VoiceprintMatchCandidate` by hand -- no actor, no file I/O -- since the whole point
/// of this pure `decide(candidate:threshold:margin:)` split is that it needs neither.
@Suite("VoiceprintMatchPolicy")
struct VoiceprintMatchPolicyTests {
    private func makeSpeaker(id: String = UUID().uuidString, name: String) -> VoiceprintSpeaker {
        VoiceprintSpeaker(
            id: id, name: name, embedding: [], createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Threshold boundary (design: "distance < threshold", never "<=")

    @Test("distance strictly below threshold, no runner-up, is accepted")
    func distanceBelowThresholdNoRunnerUpIsAccepted() {
        let candidate = VoiceprintStore.VoiceprintMatchCandidate(
            speaker: makeSpeaker(name: "田中さん"), distance: 0.5, runnerUp: nil
        )
        #expect(VoiceprintMatchPolicy.decide(candidate: candidate, threshold: 0.65, margin: 0.05) == .accepted)
    }

    @Test("distance exactly at threshold is rejectedByThreshold, not accepted")
    func distanceAtThresholdIsRejected() {
        // 0.625 (5/8) is exactly representable in both Float and Double, so `Double(candidate.distance)`
        // promotes to precisely `0.625` with no rounding drift -- unlike e.g. `0.65`, whose nearest
        // Float value is fractionally *less* than the Double `0.65`, which would silently flip this
        // exact-boundary case to `.accepted` instead of exercising the "distance < threshold" cutoff.
        let candidate = VoiceprintStore.VoiceprintMatchCandidate(
            speaker: makeSpeaker(name: "田中さん"), distance: 0.625, runnerUp: nil
        )
        #expect(VoiceprintMatchPolicy.decide(candidate: candidate, threshold: 0.625, margin: 0.05) == .rejectedByThreshold)
    }

    @Test("distance above threshold is rejectedByThreshold regardless of the margin")
    func distanceAboveThresholdIsRejectedByThreshold() {
        let candidate = VoiceprintStore.VoiceprintMatchCandidate(
            speaker: makeSpeaker(name: "田中さん"), distance: 0.7, runnerUp: .init(name: "佐藤さん", distance: 0.9)
        )
        #expect(VoiceprintMatchPolicy.decide(candidate: candidate, threshold: 0.65, margin: 0.05) == .rejectedByThreshold)
    }

    // MARK: - Margin boundary (design: "runnerUpDistance - distance >= margin")

    @Test("a runner-up gap exactly equal to the margin is accepted (>=, not >)")
    func marginGapExactlyEqualToMarginIsAccepted() {
        // 0.25/0.375/0.125 are all exactly representable in Float and Double (powers of two), so the
        // gap arithmetic (`runnerUpDistance - distance`) lands on precisely `0.125` with no rounding
        // drift that could silently flip this exact-boundary case.
        let candidate = VoiceprintStore.VoiceprintMatchCandidate(
            speaker: makeSpeaker(name: "田中さん"), distance: 0.25, runnerUp: .init(name: "佐藤さん", distance: 0.375)
        )
        #expect(VoiceprintMatchPolicy.decide(candidate: candidate, threshold: 0.65, margin: 0.125) == .accepted)
    }

    @Test("a runner-up gap just below the margin is rejectedByMargin")
    func marginGapJustBelowMarginIsRejected() {
        let candidate = VoiceprintStore.VoiceprintMatchCandidate(
            speaker: makeSpeaker(name: "田中さん"), distance: 0.4, runnerUp: .init(name: "佐藤さん", distance: 0.449)
        )
        #expect(VoiceprintMatchPolicy.decide(candidate: candidate, threshold: 0.65, margin: 0.05) == .rejectedByMargin)
    }

    // MARK: - No runner-up (single registration, or every entry shares the same name)

    @Test("a nil runnerUpDistance (no distinctly-named competitor) never triggers a margin rejection")
    func nilRunnerUpDistanceNeverRejectsByMargin() {
        let candidate = VoiceprintStore.VoiceprintMatchCandidate(
            speaker: makeSpeaker(name: "田中さん"), distance: 0.1, runnerUp: nil
        )
        #expect(VoiceprintMatchPolicy.decide(candidate: candidate, threshold: 0.65, margin: 0.05) == .accepted)
    }

    // MARK: - margin == 0 reproduces the pre-margin "distance < threshold" behavior exactly

    @Test("margin == 0 accepts whenever distance < threshold, no matter how close the runner-up is")
    func zeroMarginReproducesLegacyThresholdOnlyBehavior() {
        let candidate = VoiceprintStore.VoiceprintMatchCandidate(
            speaker: makeSpeaker(name: "田中さん"), distance: 0.5, runnerUp: .init(name: "佐藤さん", distance: 0.5)
        )
        #expect(VoiceprintMatchPolicy.decide(candidate: candidate, threshold: 0.65, margin: 0) == .accepted)
    }
}
