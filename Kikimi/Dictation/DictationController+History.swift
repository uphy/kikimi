import Foundation

// MARK: - DictationController history bookkeeping (`docs/design/29-dictation-history.md` §4.4)

/// The begin/finalize/discard half of `DictationController`'s history wiring, split out of
/// `DictationController.swift` once the two-pass decode wiring
/// (`docs/design/31-dictation-two-pass-decode.md`) pushed that file past SwiftLint's 600-line
/// file-length limit -- the same reason `DictationSettingsTab` left `SettingsView.swift`. Same
/// `@MainActor` type, only the file boundary changed (which is why the stored properties these
/// methods consume -- `historyEntryHandle` and friends -- are `internal` on the main declaration).
extension DictationController {
    /// Writes and prunes this utterance's `entry.json` in a fire-and-forget child `Task`
    /// (`docs/design/29-dictation-history.md` §4.4/DH6) once insertion has been decided. A no-op
    /// when there is no active history entry (history disabled, or an already-discarded entry --
    /// `historyEntryHandle`'s presence, not a re-read of `config.history.enabled`, is the gate;
    /// see `handleHotkeyUp()`'s doc comment).
    func finalizeHistoryEntryIfNeeded(
        durationMs: Int,
        capturedTarget: FrontmostGuard.Target,
        rawSelection: DictationRawSelection,
        refineFields: DictationRefineHistoryFields,
        insertOutcome: DictationInsertOutcome,
        maxEntries: Int,
        micDeviceInfo: DictationMicDeviceResolver.MicDeviceInfo?
    ) {
        guard let handle = historyEntryHandle, let recordedAt = historyEntryRecordedAt else { return }
        historyEntryHandle = nil
        historyEntryRecordedAt = nil
        capturedMicDeviceInfo = nil

        let entry = DictationHistoryEntry(
            recordedAt: recordedAt,
            durationMs: durationMs,
            targetBundleId: capturedTarget.bundleId,
            rawText: rawSelection.rawText,
            rawSource: rawSelection.source == .batch ? .batch : .streaming,
            streamingText: rawSelection.streamingText,
            refinedText: refineFields.outcome == .success ? refineFields.finalText : nil,
            finalText: refineFields.finalText,
            refineOutcome: refineFields.outcome,
            refineError: refineFields.error,
            insertOutcome: insertOutcome == .inserted ? .inserted : .abortedAndStashed,
            llmUsage: refineFields.llmUsage,
            micDeviceName: micDeviceInfo?.name,
            micDeviceUID: micDeviceInfo?.uid
        )

        let historyStore = historyStore
        let logger = logger
        Task {
            do {
                try await historyStore.finalize(handle: handle, entry: entry, maxEntries: maxEntries)
            } catch {
                logger.error("dictation history finalize failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Single cleanup path for every "began a history entry but will never finalize it" exit out of
    /// `handleHotkeyUp()` (and the mic-start failure exit out of `handleHotkeyDown()`): consumes the
    /// active-entry state and deletes the entry's folder (DH10). A no-op when there is no active
    /// handle -- history is disabled, or `beginEntry` hasn't completed yet (accepted
    /// super-short-press race; the folder it created is later picked up by `finalize(...)`'s
    /// orphan sweep).
    func discardActiveHistoryEntry() async {
        guard let handle = historyEntryHandle else { return }
        historyEntryHandle = nil
        historyEntryRecordedAt = nil
        capturedMicDeviceInfo = nil
        await historyStore.deleteEntry(id: handle.id)
    }

    /// `beginEntry`-and-record-the-handle step of `handleHotkeyDown()`'s mic-start `Task`, split out
    /// as its own `internal` (not `private`) seam so `DictationControllerHistoryTests` can exercise
    /// it without going through `handleHotkeyDown()`'s real `DictationAudioInput`/mic dependency.
    /// Returns the `recordingURL` `DictationAudioInput`'s init should receive
    /// (`historyEntryHandle?.audioFileURL`, or `nil` when history is disabled or `beginEntry` failed).
    func beginHistoryEntryIfNeeded(historyEnabled: Bool, startedAt: Date) async -> URL? {
        guard historyEnabled else { return nil }
        do {
            let handle = try await historyStore.beginEntry(startedAt: startedAt)
            historyEntryHandle = handle
            historyEntryRecordedAt = startedAt
            return handle.audioFileURL
        } catch {
            logger.warning("failed to begin dictation history entry, continuing without history for this utterance: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
