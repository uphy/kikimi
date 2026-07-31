import Foundation

// MARK: - RealtimeDiarizationCoordinator + SlotNumbering (docs/design/13-speaker-diarization.md section 5.1)

/// Split into its own file (alongside `+Voiceprint.swift`/`+Rematch.swift`/`+Anchor.swift`) to keep
/// `RealtimeDiarizationCoordinator.swift` under the project's `file_length` lint limit. Owns design
/// section 5.1's whole `spk_N` numbering rule: mapping the backend's per-generation internal speaker
/// index onto a session-scoped slot id, and restoring the never-reused counter from disk at the start
/// of every generation.
extension RealtimeDiarizationCoordinator {
    /// Design section 5.1's slot-numbering rule: `internalIndexToSlot[index]` if already assigned this
    /// generation, otherwise the next unused `spk_N` (`maxAllocatedSlotNumber + 1`, never reused).
    func allocateSlot(forInternalIndex index: Int) -> String {
        if let existing = internalIndexToSlot[index] {
            return existing
        }
        maxAllocatedSlotNumber += 1
        let slot = "spk_\(maxAllocatedSlotNumber)"
        internalIndexToSlot[index] = slot
        return slot
    }

    /// Restores `maxAllocatedSlotNumber` from the higher of `diarization.jsonl`'s and
    /// `speaker_assignments.json`'s highest existing `spk_N` (design section 5.1: "diarization.jsonl と
    /// speaker_assignments.json 両方の最大 slot 番号を復元して続番から採番する"). Only ever raises the
    /// in-memory counter (via `max(...)`), so a mid-lifetime call (every `beginSegment`, not only the
    /// very first) can never regress numbering that this coordinator itself already allocated but has
    /// not yet durably persisted anywhere.
    ///
    /// The two reads are wrapped in **separate** `do`/`catch` blocks, not one shared block: a
    /// `speaker_assignments.json` read failure (e.g. corrupt JSON) must not also discard whatever
    /// `diarization.jsonl` already told us, and vice versa — a single shared `do`/`catch` would abort
    /// the whole function on the first throw, silently dropping the other, still-healthy file's
    /// contribution to `maxAllocatedSlotNumber` and risking a slot-number collision the very next
    /// `allocateSlot(forInternalIndex:)` call. Each failure is logged and otherwise ignored —
    /// best-effort, matching design section 8's "voiceprints.json...破損 → warning + 空 DB として再スタート"
    /// tolerance for sidecar-file corruption.
    func restoreSlotCounterFromDisk() async {
        var maxFromTurns = 0
        do {
            let turns = try await sessionHandle.readDiarizationTurns()
            maxFromTurns = turns.compactMap { Self.slotNumber(from: $0.slot) }.max() ?? 0
        } catch {
            logger.error("failed to restore the diarization slot counter from diarization.jsonl: \(String(describing: error), privacy: .public)")
        }

        var maxFromAssignments = 0
        do {
            let assignments = try await sessionHandle.readSpeakerAssignments()
            maxFromAssignments = assignments.assignments.keys.compactMap { Self.slotNumber(from: $0) }.max() ?? 0
        } catch {
            logger.error("failed to restore the diarization slot counter from speaker_assignments.json: \(String(describing: error), privacy: .public)")
        }

        maxAllocatedSlotNumber = max(maxAllocatedSlotNumber, maxFromTurns, maxFromAssignments)
    }

    /// Parses the trailing integer out of a `"spk_N"` slot id, or `nil` for anything else
    /// (defensively — every slot this coordinator itself ever writes matches this shape).
    static func slotNumber(from slot: String) -> Int? {
        guard slot.hasPrefix("spk_") else {
            return nil
        }
        return Int(slot.dropFirst("spk_".count))
    }}
