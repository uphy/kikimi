import Foundation

// MARK: - VoiceprintMapLayout

/// Pure computation layer for the speaker map (`docs/design/19-voiceprint-map.md`): projects the
/// registered speakers' 256-d voiceprint embeddings onto 2D via PCA (§3 — mathematically identical
/// to classical MDS on their Euclidean distances, since the embeddings are L2-normalized), finds
/// same-person-suspect pairs by *true* 256-d cosine distance (§4's invariant: never derive distance
/// judgements from the 2D projection), and supplies the per-speaker nearest-neighbor list (§5).
///
/// Everything here is a deterministic pure function with no I/O and no logging — exclusions are
/// reported through return values and logged by the caller (`SettingsViewModel`), per §6. Kept next
/// to `VoiceprintStore.swift` because the math is a store-adjacent concern (it reuses
/// `VoiceprintStore.cosineDistance`'s semantics), while presentation stays in
/// `Kikimi/Views/VoiceprintMapView.swift`.
enum VoiceprintMapLayout {
    // MARK: Result types

    struct SpeakerPoint: Equatable, Identifiable, Sendable {
        let speakerId: String
        let x: Double
        let y: Double
        var id: String { speakerId }
    }

    /// Why a speaker was left out of the map (design §3.2 step 2 / §7). Checked in this order, so a
    /// speaker failing several criteria reports the first one.
    enum ExclusionReason: String, Equatable, Sendable {
        case empty
        case nonFinite
        case zeroVector
        case lengthMismatch
    }

    struct ExcludedSpeaker: Equatable, Sendable {
        let speakerId: String
        let reason: ExclusionReason
    }

    /// A pair whose true 256-d cosine distance is strictly below the match threshold — the design's
    /// "same person?" warning unit (§4). `firstId < secondId` (canonical order), no duplicates.
    ///
    /// `id` must combine BOTH speaker ids: one speaker can appear in several pairs (e.g. A–B and
    /// A–C), so identifying by `firstId` alone makes SwiftUI's `ForEach` collapse them into
    /// duplicate renders of the first pair.
    struct ClosePair: Equatable, Sendable, Identifiable {
        let firstId: String
        let secondId: String
        let distance: Float

        var id: String { "\(firstId)|\(secondId)" }
    }

    struct Neighbor: Equatable, Sendable {
        let speakerId: String
        let distance: Float
    }

    // MARK: - compute (PCA)

    /// Projects every includable speaker onto 2D (design §3.2). Deterministic: the input is
    /// canonicalized by sorting on speaker id first (step 1), so shuffled input produces
    /// bit-identical output, and the sign convention (step 7) fixes each axis's mirror ambiguity.
    static func compute(
        speakers: [VoiceprintSpeaker]
    ) -> (points: [SpeakerPoint], excluded: [ExcludedSpeaker]) {
        let (valid, excluded) = partitionValidSpeakers(speakers)
        guard !valid.isEmpty else { return ([], excluded) }

        // Steps 3–4: defensive L2 normalization, then mean-centering.
        let normalized = valid.map { speaker in l2Normalized(speaker.embedding.map(Double.init)) }
        let dimension = normalized[0].count
        var mean = [Double](repeating: 0, count: dimension)
        for vector in normalized {
            for index in 0..<dimension { mean[index] += vector[index] }
        }
        for index in 0..<dimension { mean[index] /= Double(normalized.count) }
        let centered = normalized.map { vector in
            (0..<dimension).map { vector[$0] - mean[$0] }
        }

        // Step 5: Gram matrix G = X·Xᵀ (N×N, tiny) and its top-2 eigenpairs via power iteration +
        // deflation. Chosen over Accelerate/LAPACK deliberately — see §3.2 step 5 for the
        // ACCELERATE_NEW_LAPACK build-flag friction this avoids.
        let count = centered.count
        var gram = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        for row in 0..<count {
            for column in row..<count {
                var dot: Double = 0
                for index in 0..<dimension { dot += centered[row][index] * centered[column][index] }
                gram[row][column] = dot
                gram[column][row] = dot
            }
        }

        let first = dominantEigenpair(of: gram)
        let deflated = deflate(gram, eigenpair: first)
        let second = dominantEigenpair(of: deflated)

        // Step 6: coordinates = (√λ₁·v₁, √λ₂·v₂), clamping negative eigenvalues to 0 before the
        // square root — G is PSD in theory, but rounding can push a theoretical-0 eigenvalue (e.g.
        // λ₂ with exactly 2 speakers) slightly negative, and without the clamp √λ produces NaN
        // coordinates that leak into drawing.
        let scale1 = max(first.value, 0).squareRoot()
        let scale2 = max(second.value, 0).squareRoot()
        var xs = (0..<count).map { scale1 * first.vector[$0] }
        var ys = (0..<count).map { scale2 * second.vector[$0] }

        // §7's last resort: a non-finite layout (power iteration blew up) yields "no map", never
        // NaN points handed to the view.
        guard xs.allSatisfy(\.isFinite), ys.allSatisfy(\.isFinite) else { return ([], excluded) }

        // Step 7: sign convention — flip each axis so its largest-magnitude component (first in
        // canonical order on ties) is positive.
        applySignConvention(to: &xs)
        applySignConvention(to: &ys)

        let points = valid.enumerated().map { index, speaker in
            SpeakerPoint(speakerId: speaker.id, x: xs[index], y: ys[index])
        }
        return (points, excluded)
    }

    // MARK: - closePairs (true-distance threshold warnings)

    /// All pairs of includable speakers whose true cosine distance is strictly below `threshold`,
    /// sorted closest-first. Comparison direction matches `VoiceprintMatchPolicy.decide`'s threshold
    /// check exactly: `Double(distance) < threshold` — promoting the Float distance to Double, never
    /// rounding the Double threshold down to Float (0.65 is not exactly representable as Float, so the
    /// other direction could flip boundary segments).
    static func closePairs(speakers: [VoiceprintSpeaker], threshold: Double) -> [ClosePair] {
        let (valid, _) = partitionValidSpeakers(speakers)
        var pairs: [ClosePair] = []
        for first in 0..<valid.count {
            for second in (first + 1)..<valid.count {
                let distance = VoiceprintStore.cosineDistance(
                    valid[first].embedding, valid[second].embedding
                )
                guard Double(distance) < threshold else { continue }
                pairs.append(
                    ClosePair(
                        firstId: valid[first].id,
                        secondId: valid[second].id,
                        distance: distance
                    )
                )
            }
        }
        return pairs.sorted { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            if lhs.firstId != rhs.firstId { return lhs.firstId < rhs.firstId }
            return lhs.secondId < rhs.secondId
        }
    }

    // MARK: - neighbors (per-speaker nearest list)

    /// The design §5 proximity list: the `topN` includable speakers closest to `speakerId`,
    /// regardless of threshold. Sort rule matches `KnownSpeakerSort` — ascending distance,
    /// descending `updatedAt` on ties — so the two "which voice is closest" orderings in the app
    /// can never disagree. Returns `[]` when `speakerId` is unknown or itself excluded.
    static func neighbors(
        of speakerId: String,
        in speakers: [VoiceprintSpeaker],
        topN: Int
    ) -> [Neighbor] {
        let (valid, _) = partitionValidSpeakers(speakers)
        guard let target = valid.first(where: { $0.id == speakerId }), topN > 0 else { return [] }
        return valid
            .filter { $0.id != speakerId }
            .map { speaker in
                (speaker: speaker, distance: VoiceprintStore.cosineDistance(target.embedding, speaker.embedding))
            }
            .sorted { lhs, rhs in
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                return lhs.speaker.updatedAt > rhs.speaker.updatedAt
            }
            .prefix(topN)
            .map { Neighbor(speakerId: $0.speaker.id, distance: $0.distance) }
    }

    // MARK: - Shared preprocessing (design §3.2 steps 1–2)

    /// Canonicalizes (sorts by id) and splits off speakers whose embeddings can't participate.
    /// Shared by all three public APIs so the map, the threshold edges, and the neighbor lists
    /// always agree on the population.
    private static func partitionValidSpeakers(
        _ speakers: [VoiceprintSpeaker]
    ) -> (valid: [VoiceprintSpeaker], excluded: [ExcludedSpeaker]) {
        let canonical = speakers.sorted { $0.id < $1.id }

        // Reference length = the most common length among non-empty embeddings; ties go to the
        // longer one (§3.2 step 2). Computed before per-speaker checks so one malformed entry
        // can't redefine "normal" for everyone else.
        var lengthCounts: [Int: Int] = [:]
        for speaker in canonical where !speaker.embedding.isEmpty {
            lengthCounts[speaker.embedding.count, default: 0] += 1
        }
        let referenceLength = lengthCounts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key < rhs.key
        }?.key

        var valid: [VoiceprintSpeaker] = []
        var excluded: [ExcludedSpeaker] = []
        for speaker in canonical {
            if let reason = exclusionReason(for: speaker.embedding, referenceLength: referenceLength) {
                excluded.append(ExcludedSpeaker(speakerId: speaker.id, reason: reason))
            } else {
                valid.append(speaker)
            }
        }
        return (valid, excluded)
    }

    private static func exclusionReason(
        for embedding: [Float],
        referenceLength: Int?
    ) -> ExclusionReason? {
        guard !embedding.isEmpty else { return .empty }
        guard embedding.allSatisfy(\.isFinite) else { return .nonFinite }
        guard embedding.contains(where: { $0 != 0 }) else { return .zeroVector }
        guard embedding.count == referenceLength else { return .lengthMismatch }
        return nil
    }

    // MARK: - Linear algebra helpers

    /// Zero vectors are excluded before this runs (step 2), so the guard is belt-and-suspenders.
    private static func l2Normalized(_ vector: [Double]) -> [Double] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Dominant eigenpair of a symmetric PSD matrix by power iteration. Deterministic: fixed
    /// start vector (index-skewed so it is never orthogonal to a generic dominant eigenvector),
    /// fixed tolerance, fixed iteration cap. A (near-)zero matrix — e.g. the deflated Gram matrix
    /// of exactly 2 speakers, where λ₂'s theoretical value is 0 — converges immediately to
    /// eigenvalue 0, which step 6's clamp turns into a flat axis rather than NaN. Per §7, hitting
    /// the iteration cap keeps the current approximation (harmless for PSD input).
    private static func dominantEigenpair(of matrix: [[Double]]) -> (value: Double, vector: [Double]) {
        let count = matrix.count
        var vector = (0..<count).map { 1 + Double($0) / Double(count) }
        normalize(&vector)

        var eigenvalue: Double = 0
        for _ in 0..<1000 {
            var next = multiply(matrix, vector)
            let norm = next.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 1e-12 else { return (0, vector) }
            for index in 0..<count { next[index] /= norm }
            // Rayleigh quotient of the *normalized* iterate — for symmetric PSD matrices this is
            // the eigenvalue estimate that pairs with `next`.
            eigenvalue = dot(next, multiply(matrix, next))
            let delta = zip(next, vector).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
            vector = next
            if delta < 1e-20 { break }
        }
        return (eigenvalue, vector)
    }

    private static func deflate(
        _ matrix: [[Double]], eigenpair: (value: Double, vector: [Double])
    ) -> [[Double]] {
        let count = matrix.count
        var result = matrix
        for row in 0..<count {
            for column in 0..<count {
                result[row][column] -= eigenpair.value * eigenpair.vector[row] * eigenpair.vector[column]
            }
        }
        return result
    }

    /// Flips `axis` so its largest-magnitude component (first index on exact ties — deterministic
    /// because the input is already in canonical id order) is positive.
    private static func applySignConvention(to axis: inout [Double]) {
        guard let pivot = axis.max(by: { abs($0) < abs($1) }),
              let pivotIndex = axis.firstIndex(where: { abs($0) == abs(pivot) }),
              axis[pivotIndex] < 0
        else { return }
        for index in 0..<axis.count { axis[index] = -axis[index] }
    }

    private static func multiply(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
        matrix.map { row in dot(row, vector) }
    }

    private static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func normalize(_ vector: inout [Double]) {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return }
        for index in 0..<vector.count { vector[index] /= norm }
    }
}
