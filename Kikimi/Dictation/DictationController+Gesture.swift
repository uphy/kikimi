import Foundation

// MARK: - DictationController gesture handling (§4)

/// The hotkey key-down/key-up gesture half of `DictationController`'s wiring, split out of
/// `DictationController.swift` once the dictation word-drop fixes (trailing capture grace period,
/// concurrent history-entry creation, mic-preparing HUD phase) pushed that file past SwiftLint's
/// 600-line file-length limit -- the same reason `DictationController+History.swift` and
/// `DictationController+Refine.swift` exist. Same `@MainActor` type, only the file boundary
/// changed (which is why the stored properties these methods consume are `internal` on the main
/// declaration).
extension DictationController {
    /// User-facing notifications (`UNUserNotificationCenter`) were dropped after D1 shipped: the
    /// cases they covered (warm-not-finished, misfire-guard stash) are hard to trigger on demand
    /// for hand verification, so their delivery was never actually confirmed. Every refusal/abort
    /// path below logs instead -- `docs/design/25-dictation-mode.md` §3.3/§8/R5 note this.
    func handleHotkeyDown() {
        let decision = DictationHotkeyDownDecision.decide(state: state, isTranscriberReady: transcriber != nil)

        switch decision {
        case .ignore:
            logger.debug("dictation hotkey pressed while state=\(String(describing: self.state), privacy: .public); ignoring")
            return
        case .refuseNotWarmedUp:
            logger.notice("dictation hotkey pressed before the STT backend finished warming; ignoring")
            return
        case .start:
            break
        }

        guard let transcriber else { return }

        // Hotkey key-down's real time (`docs/design/29-dictation-history.md` §3.2's `recorded_at`),
        // captured before anything else below so it stays accurate even though the history entry
        // itself is only begun a few lines later, inside the mic-start `Task`.
        let capturedAt = Date()
        capturedTarget = inserter.captureTarget()
        setState(.capturing)
        pendingRelease = false
        liveHUDPanelController().show()

        // Enqueued on the transcriber actor before any `feed(samples:)` call the mic callback
        // below could produce, so the encoder/decoder cache reset always happens first even
        // though this `Task` isn't awaited here (actor jobs run in submission order).
        Task { await transcriber.beginUtterance() }

        let config = dictationConfigProvider()
        let deviceUID = config.micDeviceUID
        let historyEnabled = config.history.enabled
        // Resolved now, not at finalize time (design 29 §3.2 addendum).
        capturedMicDeviceInfo = DictationMicDeviceResolver.resolve(configuredUID: deviceUID, enumerator: audioInputEnumerator)
        Task { [weak self] in
            guard let self else { return }

            // Word-drop fix 3a: run `beginHistoryEntryIfNeeded`'s directory-creation I/O
            // concurrently with the mic startup below (`async let`) instead of `await`ing it first
            // (the pre-fix ordering, `docs/design/29-dictation-history.md` §4.4) -- that used to
            // needlessly delay the mic by however long the I/O took. `recordingURL` is attached to
            // the already-running `DictationAudioInput` once this resolves; `history.enabled ==
            // false` resolves to `nil` immediately, so DH1's stateless path is unaffected.
            async let recordingURLTask = self.beginHistoryEntryIfNeeded(historyEnabled: historyEnabled, startedAt: capturedAt)

            // design 31 TP4/§3.2: the key-down config snapshot decides whether this utterance
            // keeps its samples in memory for the key-up batch re-decode.
            let input = DictationAudioInput(
                deviceUID: deviceUID,
                accumulateSamples: config.twoPassDecode
            )
            do {
                try await input.start { [weak self] samples in
                    Task { @MainActor [weak self] in
                        guard let self, self.state == .capturing, let transcriber = self.transcriber else { return }
                        // Word-drop fix 3b: switches the HUD from "マイク準備中…" to capturing on the
                        // mic's first actually-delivered buffer (`DictationLiveHUDPresenting`).
                        self.liveHUDPanel?.markCapturing()
                        if let cumulativeText = try? await transcriber.feed(samples: samples) {
                            self.liveHUDPanel?.updateText(cumulativeText)
                        }
                    }
                }
            } catch {
                self.logger.error("dictation mic capture failed to start: \(String(describing: error), privacy: .public)")
                if self.state == .capturing {
                    self.setState(.idle)
                }
                self.liveHUDPanel?.hide()
                // `recordingURLTask` may already have begun (or even finished) a history entry --
                // await it first so `historyEntryHandle` is set before discarding, the same ordering
                // `discardActiveHistoryEntry()`'s doc comment already documents for the pre-existing
                // "beginEntry hasn't completed yet" race.
                _ = await recordingURLTask
                await self.discardActiveHistoryEntry()
                return
            }

            // Attach the WAV writer once history's `await` resolves, before the pendingRelease
            // check below can call `input.stop()` -- `stop()` only closes a writer that is already
            // open, so attaching has to happen first or a very-short-press race would leave the
            // just-opened file unclosed.
            if let recordingURL = await recordingURLTask {
                input.attachHistoryRecording(url: recordingURL)
            }

            // key-up may have already arrived while `input.start` was in flight (a very short
            // press): stop immediately rather than leaving the mic open with nothing consuming it.
            if self.pendingRelease {
                input.stop()
            } else {
                self.audioInput = input
            }
        }
    }

    /// Not `private` (unlike `handleHotkeyDown()`): `DictationControllerHistoryTests` calls this
    /// directly after `simulateCapturing(...)` to drive the post-capture path without a real
    /// hotkey/mic (`docs/design/29-dictation-history.md` §9's layer-1 test list).
    func handleHotkeyUp() {
        guard state == .capturing else { return }
        pendingRelease = true
        setState(.transcribing)
        // design 32 HR1: with refine enabled the release-to-insert tail is LLM-dominated (seconds),
        // so the HUD switches to its "整形中…" phase and stays up until the tail ends -- users who
        // see it are less likely to switch apps mid-tail and trip the `FrontmostGuard` abort.
        // Without refine the tail is sub-0.2s, so keep design 25 H1's immediate hide. The config
        // snapshot moves here (key-up instant) from the tail `Task`, consistent with design 31 TP9's
        // key-up re-read. Both stay synchronous with key-up (not moved behind the trailing-capture
        // wait below) so the HUD reacts to key-up instantly.
        let config = dictationConfigProvider()
        if config.refine {
            liveHUDPanel?.beginProcessing()
        } else {
            liveHUDPanel?.hide()
        }

        Task { [weak self] in
            guard let self else { return }

            // Word-drop fix 1: keep the mic capturing for a short trailing grace period after
            // key-up before `stop()`, so a word spoken right at release isn't cut off mid-syllable.
            // `state` is already `.transcribing` above, so `feed(samples:)` in `handleHotkeyDown()`
            // stops firing right at key-up -- but `DictationAudioInput` keeps tee'ing to `audio.wav`
            // and accumulating `recordedSamples` regardless of `state`, so both the history WAV and
            // the key-up batch re-decode (design 31 TP4) end up including this tail; only the
            // streaming raw text itself does not.
            try? await Task.sleep(for: .milliseconds(self.trailingCaptureDelayMs))

            // Read *after* `stop()`, per `docs/design/29-dictation-history.md` §4.2: `stop()`'s
            // `WavFileWriter.close()` does a `writerQueue.sync` that blocks until every tap-thread
            // buffer already delivered has been appended to `audio.wav`. Reading the counter first
            // would race that in-flight append and could undercount `duration_ms` relative to what's
            // actually on disk -- exactly the "尻切れ再生" failure §4.2 warns about.
            self.audioInput?.stop()
            let recordedSampleCount = self.audioInput?.recordedSampleCount ?? 0
            // The `simulatedRecordedSamples` arm only ever fires under `simulateCapturing(...)` (tests).
            let recordedSamples = self.audioInput?.recordedSamples ?? self.simulatedRecordedSamples
            self.audioInput = nil

            // `docs/design/29-dictation-history.md` §4.2: sample count -> milliseconds at 16kHz mono.
            let durationMs = recordedSampleCount * 1_000 / 16_000

            // `guard`s below (rather than a synchronous check before this `Task`, as D1/D2
            // originally had it) so every non-finalizing exit -- including this one -- can uniformly
            // `await discardActiveHistoryEntry()` (§4.4's single cleanup-function requirement, DH10).
            // Each exit hides the HUD (design 32 HR4) right before `state = .idle` -- once `.idle`
            // is visible the next key-down can `show()` again, so a hide placed after a suspension
            // point could erase the *next* utterance's HUD.
            guard let transcriber = self.transcriber, let capturedTarget = self.capturedTarget else {
                self.liveHUDPanel?.hide()
                self.setState(.idle)
                await self.discardActiveHistoryEntry()
                return
            }

            let streamingRaw: String
            do {
                streamingRaw = try await transcriber.finishUtterance()
            } catch {
                self.logger.error("dictation STT finish failed: \(String(describing: error), privacy: .public)")
                self.liveHUDPanel?.hide()
                self.setState(.idle)
                await self.discardActiveHistoryEntry()
                return
            }

            // design 31 TP2/TP6: re-decode the whole utterance with the batch model (when
            // available) and let it take precedence over the streaming text -- the streaming
            // decoder deterministically drops words after mid-utterance pauses (the design's 経緯).
            let batchText = await self.decodeBatchIfEnabled(samples: recordedSamples, twoPassDecode: config.twoPassDecode)

            guard let selection = DictationRawSelection.select(batchText: batchText, streamingText: streamingRaw) else {
                self.capturedTarget = nil
                self.liveHUDPanel?.hide()
                self.setState(.idle)
                // DH10 (unchanged by design 31): a begun-but-empty utterance (0-second press, or
                // the super-short-press race documented on `handleHotkeyDown()`) never becomes a
                // history entry -- both decoders producing only whitespace counts as empty.
                await self.discardActiveHistoryEntry()
                return
            }
            let trimmedRaw = selection.rawText
            // design 32 HR2: let the user read the confirmed (batch-preferred) raw while the
            // refinement runs. A display no-op when refine is off (the HUD is already hidden).
            self.liveHUDPanel?.updateText(trimmedRaw)

            // D2: `finalText` is the refined text on success, or `trimmedRaw` unchanged on
            // timeout/error/offline (R9's fallback -- `DictationRefiner.refine` never throws).
            // `refineFields` additionally carries this utterance's `entry.json` refinement
            // bookkeeping (`docs/design/29-dictation-history.md` §3.2/§4.4).
            let refineFields = await self.refineForHistory(rawText: trimmedRaw, config: config, capturedTarget: capturedTarget)

            self.setState(.inserting)
            let outcome = self.inserter.insert(text: refineFields.finalText, capturedTarget: capturedTarget, method: config.insertMethod)
            // design 32 HR6: hide the HUD before the abort overlay can appear, so the two panels
            // never overlap on screen.
            self.liveHUDPanel?.hide()
            // R5/§3.6: the overlay panel is D2-only -- D1's release-to-insert window is short
            // enough (no refinement wait) that the design doc treats a plain clipboard stash as
            // sufficient. `config.refine` (not whether refinement actually changed the text) is
            // the right gate: even a timeout-to-raw fallback still spent the wait, raising the
            // misfire probability the panel exists to cover.
            if outcome == .abortedAndStashed, config.refine {
                self.overlayPanelController().show(text: refineFields.finalText, method: config.insertMethod)
            }
            self.capturedTarget = nil
            self.setState(.idle)

            // `docs/design/29-dictation-history.md` §4.4: finalize (or the aborted-and-stashed case,
            // DH11) after insertion has been decided, in a fire-and-forget child `Task` -- `state =
            // .idle` above does not wait for history I/O (DH6).
            self.finalizeHistoryEntryIfNeeded(
                durationMs: durationMs,
                capturedTarget: capturedTarget,
                rawSelection: selection,
                refineFields: refineFields,
                insertOutcome: outcome,
                maxEntries: config.history.maxEntries,
                micDeviceInfo: self.capturedMicDeviceInfo
            )
        }
    }

    /// The key-up batch decode with design 31 §3.3's three fall-back-to-streaming (`nil`) gates.
    /// `twoPassDecode` is the key-up config re-read (not "is `batchTranscriber` non-nil"), so an
    /// ON->OFF toggle racing this utterance still wins over a lingering warm instance (TP9).
    private func decodeBatchIfEnabled(samples: [Float], twoPassDecode: Bool) async -> String? {
        guard twoPassDecode, let batchTranscriber else { return nil }
        // Everyday short presses (and the accumulate-off-at-key-down races of §3.2) are expected,
        // not errors: FluidAudio hard-rejects < 0.3s of audio, so gate before calling it.
        guard samples.count >= DictationBatchTranscriber.minimumSampleCount else {
            logger.debug("dictation batch decode skipped: \(samples.count, privacy: .public) samples is below the model's minimum")
            return nil
        }
        do {
            return try await batchTranscriber.transcribe(samples: samples)
        } catch {
            logger.error("dictation batch decode failed, confirming from the streaming text: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
