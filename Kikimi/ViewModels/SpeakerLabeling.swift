import Foundation

// MARK: - SpeakerDisplayLabel

/// The speaker label a Transcript タブ row should render as (`docs/design/13-speaker-diarization.md`
/// section 6.1's staged display: "(認識中…) → Speaker 1 → 田中さん"). Purely a display-time derivation
/// (`SpeakerLabelResolver.resolve(...)`), never persisted -- the underlying facts live in
/// `DiarizationTurn`/`SpeakerAssignments` (`Kikimi/SessionStore/DiarizationModels.swift`).
enum SpeakerDisplayLabel: Equatable {
    /// Diarization is disabled, not yet started for this segment's time range, or has permanently
    /// stopped (design section 5.3's precondition / section 8's failure mode). Callers render this
    /// exactly like the pre-diarization physical-source label ("system"/"mic").
    case systemFallback
    /// No `DiarizationTurn` overlaps yet, and `AttributionTuning.unattributedGraceMs` has not elapsed
    /// since the segment was confirmed (design section 5.3 rule 1, "(認識中…)").
    case recognizing
    /// No `DiarizationTurn` overlaps, and the grace period has elapsed (design section 5.3 rule 1,
    /// "Speaker ?" -- e.g. BGM/notification sounds with no attributable speech).
    case unknown
    /// A slot dominates the segment but has no `displayName` yet (design section 5.3 rule 3, no
    /// rename/voiceprint match yet). `slotNumber` is the `spk_N` suffix, for rendering "Speaker N".
    case anonymous(slotNumber: Int)
    /// A slot dominates the segment and has a resolved display name (rename or, in R2, voiceprint
    /// match; design section 4.3/6.1).
    case named(String)
    /// The runner-up slot's occupancy clears `AttributionTuning.secondSpeakerMixedThreshold` (design
    /// section 5.3 rule 2, "田中さん + 佐藤さん"). Both strings are already fully resolved (either a
    /// display name or "Speaker N" -- design section 6.3's Wiki export example mixes the two freely).
    case mixed(primary: String, secondary: String)
}

// MARK: - ResolvedSpeakerLabel

/// Everything `SpeakerLabelResolver.resolve(...)` derives for one Transcript タブ row.
struct ResolvedSpeakerLabel: Equatable {
    var label: SpeakerDisplayLabel
    /// Simultaneous-speech marker (design section 5.3): "⚠ が上記と直交する付加マーカー" -- orthogonal to
    /// `label`, so it can be `true` alongside any case above.
    var hasOverlapMarker: Bool
    /// `true` when `label` came from a per-segment override ("この発言だけ変更", design section 6.1)
    /// rather than the slot-derived pipeline. The rename popover uses this to route "割り当て解除" to
    /// the override (restoring the slot-derived label) instead of clearing the whole slot's name.
    var isSegmentOverride: Bool = false
    /// The raw `spk_N` slot id(s) `SegmentAttribution.attribute(...)` resolved this segment to --
    /// `[primary]` for `.single`, `[primary, secondary]` for `.mixed`, empty for `.unattributed`/
    /// `.systemFallback`/an override with nothing underneath. `label` deliberately only carries
    /// already-resolved display strings (never a raw slot id, see its own doc comment), but the
    /// rename popover (`MeetingWorkspaceView`'s `TranscriptTabView` wiring) needs the id to submit a
    /// rename against. Populated here so callers reuse `resolve(...)`'s own
    /// `SegmentAttribution.attribute(...)` call instead of recomputing it a second time per row per
    /// render -- a former CPU-pinning/UI-freeze source (`docs/design/13-speaker-diarization.md`
    /// section 5).
    var attributedSlots: [String] = []

    /// `.systemFallback` with no overlap marker -- the label every segment starts at before
    /// diarization has anything to say about it.
    static let systemFallback = ResolvedSpeakerLabel(label: .systemFallback, hasOverlapMarker: false)
}

// MARK: - SpeakerLabelResolver

/// Pure functions mapping one Transcript タブ segment's time range, the session's accumulated
/// `DiarizationTurn`s, and `SpeakerAssignments` to a `ResolvedSpeakerLabel`
/// (`docs/design/13-speaker-diarization.md` sections 5.3/6.1). Delegates the actual occupancy/label
/// derivation to `Kikimi/Diarization/SegmentAttribution.swift` -- this type only adds the two things
/// that function deliberately leaves out: the "is diarization even active for this time range" gate
/// (section 5.3's precondition) and slot -> display-string resolution (section 4.3/6.1).
///
/// No I/O, no actor/coordinator dependency: `MeetingWorkspaceViewModel+Diarization.swift` owns
/// reading `RealtimeDiarizationCoordinator.activeRangesSnapshot()`/`SessionHandle
/// .readSpeakerAssignments()` and re-invoking this whenever new turns arrive, a slot is renamed, or
/// the unattributed-grace-period ticker fires.
enum SpeakerLabelResolver {
    /// - Parameters:
    ///   - activeRanges: Spans of the cumulative timeline during which diarization was actually
    ///     running (`RealtimeDiarizationCoordinator.activeRangesSnapshot()`). A segment whose
    ///     `[startMs, endMs)` does not overlap *any* range resolves to `.systemFallback` regardless of
    ///     `turns`/`assignments` (design section 5.3's precondition). Passing a single
    ///     `DiarizationActiveRange(startMs: 0, endMs: nil)` opts every segment into attribution --
    ///     used for backfilling a reopened session's historical rows, where this coordinator instance
    ///     never observed the original active ranges (see `MeetingWorkspaceViewModel+Diarization.swift`
    ///     's backfill doc comment for the tracked limitation this simplification accepts).
    ///   - confirmedAt: Wall-clock time this segment was confirmed into `transcriptRows` (design
    ///     section 5.3 rule 1's "セグメント確定から" anchor). Only consulted when the segment is
    ///     currently unattributed.
    ///   - now: Injectable for deterministic tests; production callers pass `Date()`.
    ///   - speakerNames: `globalSpeakerId -> current registered name` (`docs/design/23-speaker-
    ///     settings-rename.md` §2.2), built by the caller from `VoiceprintStore.listSpeakers()`. When a
    ///     slot/override carries a `globalSpeakerId` found in this map, its *current* name wins over
    ///     the snapshot `displayName` frozen in `speaker_assignments.json` at assignment time -- this is
    ///     what makes a rename in Settings' 話者 tab show up the next time a past session's labels are
    ///     recomputed, without rewriting any session's `speaker_assignments.json` on disk. Defaults to
    ///     empty so every pre-existing call site is unaffected.
    static func resolve(
        startMs: Int,
        endMs: Int,
        turns: [DiarizationTurn],
        activeRanges: [DiarizationActiveRange],
        assignments: SpeakerAssignments,
        override: SegmentSpeakerOverride? = nil,
        confirmedAt: Date,
        now: Date,
        unattributedGraceMs: Int = AttributionTuning.unattributedGraceMs,
        speakerNames: [String: String] = [:]
    ) -> ResolvedSpeakerLabel {
        let withinActiveRange = isWithinActiveRange(startMs: startMs, endMs: endMs, activeRanges: activeRanges)

        // A per-segment override ("この発言だけ変更", design section 6.1) wins over everything,
        // including the active-range precondition: the user explicitly named this utterance, which is
        // strictly better information than whether diarization happened to be running. The ⚠ marker
        // stays orthogonal (design section 5.3) -- an override names the speaker, it does not assert
        // that no simultaneous speech occurred.
        if let override {
            // Computed once (not `nil` only when `withinActiveRange`, matching `hasOverlapMarker`'s
            // existing gate) and reused for both `hasOverlapMarker` and `attributedSlots` below --
            // `ResolvedSpeakerLabel.attributedSlots`'s doc comment explains why the caller needs this
            // instead of recomputing `SegmentAttribution.attribute(...)` a second time per row.
            let attribution = withinActiveRange
                ? SegmentAttribution.attribute(startMs: startMs, endMs: endMs, turns: turns)
                : nil
            let name = resolvedName(
                displayName: override.displayName, globalSpeakerId: override.globalSpeakerId, speakerNames: speakerNames
            ) ?? override.displayName
            return ResolvedSpeakerLabel(
                label: .named(name),
                hasOverlapMarker: attribution?.hasOverlapMarker ?? false,
                isSegmentOverride: true,
                attributedSlots: attribution.map { attributedSlots(from: $0.label) } ?? []
            )
        }

        guard withinActiveRange else {
            return .systemFallback
        }

        let attribution = SegmentAttribution.attribute(startMs: startMs, endMs: endMs, turns: turns)
        let label: SpeakerDisplayLabel
        switch attribution.label {
        case .unattributed:
            let elapsedMs = now.timeIntervalSince(confirmedAt) * 1_000
            label = elapsedMs < Double(unattributedGraceMs) ? .recognizing : .unknown
        case .single(let slot):
            label = resolvedLabel(forSlot: slot, assignments: assignments, speakerNames: speakerNames)
        case .mixed(let primary, let secondary):
            label = .mixed(
                primary: displayString(forSlot: primary, assignments: assignments, speakerNames: speakerNames),
                secondary: displayString(forSlot: secondary, assignments: assignments, speakerNames: speakerNames)
            )
        }
        return ResolvedSpeakerLabel(
            label: label,
            hasOverlapMarker: attribution.hasOverlapMarker,
            attributedSlots: attributedSlots(from: attribution.label)
        )
    }

    /// The raw slot id(s) behind one `SegmentSpeakerLabel` (`ResolvedSpeakerLabel.attributedSlots`'s
    /// doc comment), in the same primary-then-secondary order `label`'s own `.mixed` case uses.
    private static func attributedSlots(from label: SegmentSpeakerLabel) -> [String] {
        switch label {
        case .unattributed:
            return []
        case .single(let slot):
            return [slot]
        case .mixed(let primary, let secondary):
            return [primary, secondary]
        }
    }

    /// `true` iff `[startMs, endMs)` overlaps at least one range in `activeRanges`. An open range
    /// (`endMs == nil`, the currently-recording segment) is treated as extending to `Int.max`.
    static func isWithinActiveRange(startMs: Int, endMs: Int, activeRanges: [DiarizationActiveRange]) -> Bool {
        activeRanges.contains { range in
            let rangeEnd = range.endMs ?? .max
            return startMs < rangeEnd && endMs > range.startMs
        }
    }

    /// Design section 5.3 rule 3 / section 4.3: `displayName` if the slot has one, else "anonymous"
    /// (rendered "Speaker N" by callers). `speakerNames` (see `resolve(...)`'s doc comment) overrides
    /// the snapshot `displayName` when the slot's `globalSpeakerId` resolves there.
    static func resolvedLabel(
        forSlot slot: String, assignments: SpeakerAssignments, speakerNames: [String: String] = [:]
    ) -> SpeakerDisplayLabel {
        let slotAssignment = assignments.assignments[slot]
        if let name = resolvedName(
            displayName: slotAssignment?.displayName, globalSpeakerId: slotAssignment?.globalSpeakerId, speakerNames: speakerNames
        ), !name.isEmpty {
            return .named(name)
        }
        return .anonymous(slotNumber: slotNumber(from: slot) ?? 0)
    }

    /// `resolvedLabel(forSlot:assignments:speakerNames:)` flattened to a display string, for `.mixed`'s
    /// two already-resolved slots (design section 5.3 rule 2 / section 6.3's Wiki export example).
    static func displayString(
        forSlot slot: String, assignments: SpeakerAssignments, speakerNames: [String: String] = [:]
    ) -> String {
        switch resolvedLabel(forSlot: slot, assignments: assignments, speakerNames: speakerNames) {
        case .named(let name):
            return name
        case .anonymous(let slotNumber):
            return "Speaker \(slotNumber)"
        case .systemFallback, .recognizing, .unknown, .mixed:
            // Unreachable: `resolvedLabel(forSlot:assignments:speakerNames:)` only ever returns
            // `.named`/`.anonymous`. Handled exhaustively rather than assumed impossible.
            return "Speaker ?"
        }
    }

    /// Shared by `resolve(...)`'s override branch and `resolvedLabel(forSlot:assignments:speakerNames:)`:
    /// prefers `speakerNames[globalSpeakerId]` (the current registered name) over the snapshot
    /// `displayName`, falling back to `displayName` when `globalSpeakerId` is `nil` (never linked to the
    /// global registry) or not found in `speakerNames` (design §2.2: the speaker was deleted from
    /// Settings since this snapshot was written -- the last known name is kept rather than reverting to
    /// "Speaker N").
    private static func resolvedName(
        displayName: String?, globalSpeakerId: String?, speakerNames: [String: String]
    ) -> String? {
        if let globalSpeakerId, let current = speakerNames[globalSpeakerId], !current.isEmpty {
            return current
        }
        return displayName
    }

    /// Parses the trailing integer out of a `"spk_N"` slot id, mirroring
    /// `RealtimeDiarizationCoordinator.slotNumber(from:)` (kept as a separate copy: that one is
    /// `private` to a different file, and this module has no shared "slot ID" utility type).
    private static func slotNumber(from slot: String) -> Int? {
        guard slot.hasPrefix("spk_") else {
            return nil
        }
        return Int(slot.dropFirst("spk_".count))
    }
}
