import Foundation

// MARK: - NormalizedRenameTarget

/// Pure name normalization shared by both free-typed rename entry points -- slot rename
/// (`MeetingWorkspaceViewModel.applyRename(slot:submission:)`) and segment override
/// (`overrideSegmentSpeaker(segmentId:submission:)`) -- per
/// `docs/design/20-voiceprint-misassignment-mitigation.md` section 4. A `.newName` the user typed is
/// resolved against the already-known global speakers by *trimmed exact name match* before either path
/// decides what to do with it, so typing an existing speaker's name is treated the same as picking that
/// speaker from the known-speaker picker instead of silently registering a duplicate `VoiceprintSpeaker`
/// (the pre-existing hole this design closes, section 4's bullet list).
///
/// No I/O -- the caller supplies the already-fetched known-speaker list
/// (`MeetingWorkspaceViewModel.knownVoiceprintSpeakers`) and this type does nothing but compare names.
/// Kept next to `SpeakerRenameDecision.swift` (this popover's other pure decision helper) rather than
/// folded into it: normalization is a *preprocessing* step shared by two different call sites (slot
/// rename and segment override), whereas `SpeakerRenameDecision` only ever governs the slot-rename
/// enrollment path.
enum NormalizedRenameTarget: Equatable, Sendable {
    /// Trimmed `name` matched exactly one known speaker: treat this the same as if the user had picked
    /// that speaker from the picker (`SpeakerRenameSubmission.existingSpeaker`, design section 4's "1
    /// 人" row). `name` is that speaker's current, not necessarily identically-whitespaced, stored name.
    case existing(globalSpeakerId: String, name: String)
    /// Trimmed `name` matched none of the known speakers: proceed with the usual new-registration path
    /// (design section 4's "0 人" row).
    case new(String)
    /// Trimmed `name` matched more than one known speaker -- an existing same-name duplicate in
    /// `voiceprints.json` (design section 4's "複数人" row). Which duplicate is the real target can't be
    /// decided mechanically, so callers must suppress *both* global registration and Ended-time EMA
    /// learning here and fall back to a session-local-only display name, rather than guessing.
    case ambiguous(String)

    /// - Parameters:
    ///   - name: The free-typed name to resolve. Always compared *trimmed* (design section 4's "前後
    ///     空白の trim"), against every known speaker's name, also trimmed -- so a stray-whitespace
    ///     registered name and a stray-whitespace typed name still match.
    ///   - knownSpeakers: The full known-speaker list (`VoiceprintStore.listSpeakers()`,
    ///     `MeetingWorkspaceViewModel.knownVoiceprintSpeakers`).
    static func resolve(name: String, knownSpeakers: [VoiceprintSpeaker]) -> NormalizedRenameTarget {
        let trimmedName = SpeakerName.trimmed(name)
        let matches = knownSpeakers.filter { SpeakerName.isSame($0.name, name) }
        switch matches.count {
        case 1:
            return .existing(globalSpeakerId: matches[0].id, name: matches[0].name)
        case 0:
            return .new(trimmedName)
        default:
            return .ambiguous(trimmedName)
        }
    }
}
