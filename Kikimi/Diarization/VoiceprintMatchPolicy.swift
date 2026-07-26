import Foundation

// MARK: - VoiceprintMatchDecision

/// The outcome of judging one `VoiceprintStore.VoiceprintMatchCandidate` against a threshold/margin
/// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 3.1). Distinct cases (rather than a
/// bare `Bool`) so `RealtimeDiarizationCoordinator+Voiceprint.swift`'s `extractAndMatchVoiceprint` can
/// log which rule rejected the candidate (design section 3.3's distance-log table).
enum VoiceprintMatchDecision: Sendable, Equatable {
    /// `distance < threshold` and either there is no runner-up or the runner-up is far enough away.
    case accepted
    /// `distance >= threshold` — too far from the nearest speaker to be considered the same person,
    /// regardless of the margin.
    case rejectedByThreshold
    /// `distance < threshold` but the runner-up (a *different-named* registered speaker, design section
    /// 3.1) is too close behind: the match is ambiguous between the nearest speaker and the runner-up.
    case rejectedByMargin
}

// MARK: - VoiceprintMatchPolicy

/// Pure accept/reject policy for one `VoiceprintStore.VoiceprintMatchCandidate`
/// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 3.1). Deliberately separated from
/// `VoiceprintStore.findMatchCandidate(embedding:)` (which only finds the nearest/runner-up speakers,
/// oblivious to any threshold) so this decision arithmetic is directly unit-testable without an actor
/// hop or a populated database, mirroring `VoiceprintStore.cosineDistance(_:_:)`'s own `nonisolated
/// static` pure-function convention.
enum VoiceprintMatchPolicy {
    /// Accepts `candidate` when its distance clears `threshold` **and** — if a runner-up exists — the
    /// gap to that runner-up is at least `margin` (design section 3.1: "受理条件: distance < threshold
    /// かつ（runnerUpDistance == nil または runnerUpDistance - distance >= margin）"). A `margin` of `0`
    /// makes the second condition trivially always true (`runnerUpDistance - distance >= 0` always
    /// holds whenever `runnerUpDistance >= distance`, which `VoiceprintStore.findMatchCandidate` always
    /// guarantees since `distance` is the minimum), reproducing the former `findBestMatch`'s
    /// margin-unaware "distance < threshold" behavior exactly (design section 3.4: "0 でマージン判定を
    /// 無効化（従来挙動）").
    static func decide(
        candidate: VoiceprintStore.VoiceprintMatchCandidate,
        threshold: Double,
        margin: Double
    ) -> VoiceprintMatchDecision {
        guard Double(candidate.distance) < threshold else {
            return .rejectedByThreshold
        }
        if let runnerUp = candidate.runnerUp {
            let gap = Double(runnerUp.distance) - Double(candidate.distance)
            guard gap >= margin else {
                return .rejectedByMargin
            }
        }
        return .accepted
    }
}
