import Foundation

// MARK: - SpeakerName

/// Canonical trimmed-name comparison shared across every "is this the same speaker name" check in the
/// R2 voiceprint feature (`docs/design/20-voiceprint-misassignment-mitigation.md` section 4's "前後空白
/// の trim" convention): `NormalizedRenameTarget.resolve(name:knownSpeakers:)`'s exact-match lookup,
/// `VoiceprintStore.findMatchCandidate(embedding:)`'s "different person" runner-up test,
/// `DisputedSlotDetector.disputedSlots(assignments:transcriptSegments:turns:)`'s slot-vs-override
/// dispute test, and `MeetingWorkspaceViewModel+OverrideEnrollment.swift`'s override write-back filter
/// all need to agree on exactly the same definition of "same name" -- this is the one place that
/// definition lives.
enum SpeakerName {
    /// `name` with leading/trailing whitespace and newlines removed -- the one normalization every
    /// comparison below is built on.
    static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `lhs`/`rhs` name the same person once both are trimmed.
    static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        trimmed(lhs) == trimmed(rhs)
    }
}
