import AppKit
import AVFoundation
import Combine
import Foundation
import KeyboardShortcuts
import OSLog

// MARK: - KeyboardShortcuts.Name

extension KeyboardShortcuts.Name {
    /// The single dictation hotkey (`docs/design/25-dictation-mode.md` R7/§5). No default shortcut
    /// is shipped -- see that section's rationale (a fixed default like `⌥Space` can silently
    /// double-fire alongside launcher tools such as Raycast).
    static let dictate = Self("dictate")
}

// MARK: - DictationController

/// `@MainActor` singleton that owns the dictation feature's full lifecycle
/// (`docs/design/25-dictation-mode.md` R1): reacts to `dictation.enabled`, warms the STT backend,
/// wires the hotkey, and drives one utterance's capture -> transcribe -> insert cycle end to end.
///
/// Deliberately stateless with respect to `SessionStore`/session windows (R1: "`SessionStore` を
/// 一切呼ばない"); it has **no** interaction with the meeting pipeline at all -- R4 originally gated
/// capture on an in-progress meeting recording, but that exclusivity was dropped after D1 shipped
/// in favor of sharing the mic.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    /// `internal` (not `private`): also used by the history-bookkeeping half of this type in
    /// `DictationController+History.swift` (split for SwiftLint's 600-line file-length limit).
    let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationController")

    @Published private(set) var state: DictationState = .disabled
    /// `true` once `AXIsProcessTrusted()` last reported trust. Re-checked on every insert attempt
    /// (permissions can be revoked at any time from System Settings), but also published so
    /// Settings can show a "grant accessibility" hint without polling.
    @Published private(set) var isAccessibilityTrusted = false

    /// `internal` (not `private`): read/set by `handleHotkeyDown()`/`handleHotkeyUp()` in
    /// `DictationController+Gesture.swift` (split for SwiftLint's 600-line file-length limit, same
    /// as `historyEntryHandle` and friends).
    var transcriber: DictationTranscriber?
    /// The warm batch decoder for the two-pass design (`docs/design/31-dictation-two-pass-decode.md`
    /// TP5/TP9). Non-`nil` only while `dictation.enabled && dictation.two_pass_decode` holds and the
    /// (possibly multi-second, download-included) warm has finished; every `nil` window -- warming,
    /// load failure, toggled off -- degrades that utterance to the streaming raw (TP2), never blocks.
    /// `internal`: also read by `DictationController+Gesture.swift`'s `decodeBatchIfEnabled`.
    var batchTranscriber: (any DictationBatchTranscribing)?
    /// `internal`: set/cleared by `handleHotkeyDown()`/`handleHotkeyUp()` (`+Gesture.swift`).
    var audioInput: DictationAudioInput?
    /// Injected (default `DictationInserter()`) -- tests substitute a spy, see `DictationInserting`.
    /// `internal`: also used by `handleHotkeyDown()`/`handleHotkeyUp()` (`+Gesture.swift`).
    let inserter: any DictationInserting
    /// `internal` (not `private`): consumed by `refineForHistory` in
    /// `DictationController+Refine.swift` (split for SwiftLint's 600-line file-length limit,
    /// same as `historyEntryHandle` and friends).
    let refiner: DictationRefiner
    /// Lazily created on first abort (D2 only) and reused across every subsequent abort -- mirrors
    /// `SettingsWindowController`'s singleton-per-window-kind lifecycle. Never created at all if
    /// `dictation.refine` stays `false` for the process's lifetime.
    private var overlayPanel: DictationOverlayPanelController?
    /// Lazily created on the first `.capturing` transition and reused across every subsequent
    /// utterance -- same singleton-per-window-kind lifecycle as `overlayPanel`. Shown in
    /// `handleHotkeyDown()`; at key-up it is either hidden immediately (`dictation.refine` off,
    /// design 25 H1) or switched to its processing phase and hidden at the end of every tail path
    /// (`docs/design/32-dictation-hud-refining-visibility.md` HR1/HR4). Held as the protocol (built
    /// by `liveHUDPanelFactory`) so layer-1 tests can substitute a spy. `internal`: also used by
    /// `handleHotkeyDown()`/`handleHotkeyUp()` (`+Gesture.swift`).
    var liveHUDPanel: (any DictationLiveHUDPresenting)?

    private var configCancellable: AnyCancellable?
    private var isHotkeyWired = false
    private var isWarming = false
    /// `isWarming`'s batch-model counterpart (design 31 §3.3): suppresses duplicate batch warms.
    private var isBatchWarming = false
    /// Test-only sample source consumed by `handleHotkeyUp()` when `audioInput == nil` (i.e. the
    /// capture was set up via `simulateCapturing(...)` rather than a real mic). Always empty in
    /// production: a real utterance reads `audioInput.recordedSamples` instead. `internal`: used
    /// by `handleHotkeyUp()` (`+Gesture.swift`).
    var simulatedRecordedSamples: [Float] = []
    /// `internal`: read/set by `handleHotkeyDown()`/`handleHotkeyUp()` (`+Gesture.swift`).
    var capturedTarget: FrontmostGuard.Target?
    /// Set by `handleHotkeyUp()` when key-up arrives before the in-flight key-down `Task` (below)
    /// has finished starting the mic -- a very short press/release. Checked once that `Task`
    /// finishes `DictationAudioInput.start(samplesHandler:)`, so the mic is stopped immediately
    /// instead of being left open with nothing consuming its samples. `internal`: read/set by
    /// `handleHotkeyDown()`/`handleHotkeyUp()` (`+Gesture.swift`).
    var pendingRelease = false

    /// `docs/design/29-dictation-history.md` §4.4: set at the top of the mic-start `Task` in
    /// `handleHotkeyDown()` when `history.enabled` and `beginEntry(startedAt:)` succeeds, consumed
    /// (set back to `nil`) by `discardActiveHistoryEntry()` or `handleHotkeyUp()`'s finalize step.
    /// `nil` doubles as the "active history entry?" gate -- deliberately not a `history.enabled` re-read.
    /// `internal` (with the two fields below and `historyStore`): also read/consumed by the
    /// history-bookkeeping extension in `DictationController+History.swift`.
    var historyEntryHandle: DictationHistoryStore.EntryHandle?
    /// The hotkey key-down instant this utterance's history entry was begun at (§3.2's
    /// `recorded_at`). Always set together with `historyEntryHandle`, cleared together with it.
    var historyEntryRecordedAt: Date?
    /// The microphone resolved for this utterance (design 29 §3.2 addendum, see
    /// `DictationMicDeviceResolver`), threaded unchanged through to `finalizeHistoryEntryIfNeeded`.
    var capturedMicDeviceInfo: DictationMicDeviceResolver.MicDeviceInfo?

    /// Injected so tests can substitute a fake without touching `AppConfig.shared` (mirrors every
    /// other Kikimi component's DI seam for `.shared` dependencies). `internal`: also read by
    /// `handleHotkeyDown()`/`handleHotkeyUp()` (`+Gesture.swift`).
    let dictationConfigProvider: @MainActor () -> DictationConfig
    private let sttConfigProvider: @MainActor () -> SttConfig
    /// `watchers.default_model`, read as `DictationRefiner.resolveModel(dictationModel:
    /// watchersDefaultModel:)`'s fallback (R9, revised: reuse Kikimi's existing "no explicit model"
    /// default instead of a separate hardcoded literal). This and the two glossary providers below
    /// are `internal` for `DictationController+Refine.swift` (see `refiner`).
    let watchersDefaultModelProvider: @MainActor () -> String
    /// `docs/design/28-glossary.md` §2: the top-level `glossary` config section, resolved here.
    let glossaryProvider: @MainActor () -> [GlossaryEntry]
    /// `docs/design/28-glossary.md` §1.2: the `glossary_categories` half of the same section.
    let glossaryCategoriesProvider: @MainActor () -> [GlossaryCategory]
    private let transcriberFactory: (SttEngineConfig) async throws -> DictationTranscriber
    /// `docs/design/31-dictation-two-pass-decode.md` §3.1's test seam: builds the warm batch
    /// decoder from the *resolved* language (`resolveSttEngineConfig`'s output, TP1).
    private let batchTranscriberFactory: (String) async throws -> any DictationBatchTranscribing
    /// `docs/design/29-dictation-history.md` §4.4/§5.1: injected the same way every other `.shared`
    /// dependency on this type is (mirrors `refiner` above), rather than through a closure provider
    /// -- unlike `dictationConfigProvider`/etc., this dependency is a single long-lived actor
    /// instance, not a per-call config snapshot. `internal` for `DictationController+History.swift`
    /// (see `historyEntryHandle`).
    let historyStore: any DictationHistoryStoring
    /// `DictationMicDeviceResolver`'s `enumerator` argument (design 29 §3.2 addendum). `internal`:
    /// read by `handleHotkeyDown()` (`+Gesture.swift`).
    let audioInputEnumerator: any AudioInputEnumerating
    /// `docs/design/32-dictation-hud-refining-visibility.md` §3.1's test seam: builds `liveHUDPanel`
    /// on the first `.capturing` transition (or in `simulateCapturing(...)` for tests).
    private let liveHUDPanelFactory: @MainActor () -> any DictationLiveHUDPresenting
    /// Word-drop fix 1's trailing capture grace period: `handleHotkeyUp()` (`+Gesture.swift`) keeps
    /// the mic open this long after key-up before `stop()`, so a word spoken right at release isn't
    /// cut off mid-syllable. Injected (default 280ms, the middle of the requested 250-300ms range)
    /// so tests can override it to `0` and stay fast.
    let trailingCaptureDelayMs: UInt64

    init(
        dictationConfigProvider: @escaping @MainActor () -> DictationConfig = { AppConfig.shared.data.dictation },
        sttConfigProvider: @escaping @MainActor () -> SttConfig = { AppConfig.shared.data.stt },
        watchersDefaultModelProvider: @escaping @MainActor () -> String = { AppConfig.shared.data.watchers.defaultModel },
        glossaryProvider: @escaping @MainActor () -> [GlossaryEntry] = { AppConfig.shared.data.glossary },
        glossaryCategoriesProvider: @escaping @MainActor () -> [GlossaryCategory] = { AppConfig.shared.data.glossaryCategories },
        transcriberFactory: @escaping (SttEngineConfig) async throws -> DictationTranscriber = DictationTranscriber.make,
        batchTranscriberFactory: @escaping (String) async throws -> any DictationBatchTranscribing = { language in
            try await DictationBatchTranscriber.make(language: language)
        },
        refiner: DictationRefiner = DictationRefiner(),
        historyStore: any DictationHistoryStoring = DictationHistoryStore.shared,
        audioInputEnumerator: any AudioInputEnumerating = AudioInputEnumerator(),
        liveHUDPanelFactory: @escaping @MainActor () -> any DictationLiveHUDPresenting = { DictationLiveHUDPanelController() },
        inserterFactory: @escaping @MainActor () -> any DictationInserting = { DictationInserter() },
        trailingCaptureDelayMs: UInt64 = 280
    ) {
        self.dictationConfigProvider = dictationConfigProvider
        self.sttConfigProvider = sttConfigProvider
        self.watchersDefaultModelProvider = watchersDefaultModelProvider
        self.glossaryProvider = glossaryProvider
        self.glossaryCategoriesProvider = glossaryCategoriesProvider
        self.audioInputEnumerator = audioInputEnumerator
        self.transcriberFactory = transcriberFactory
        self.trailingCaptureDelayMs = trailingCaptureDelayMs
        self.batchTranscriberFactory = batchTranscriberFactory
        self.refiner = refiner
        self.historyStore = historyStore
        self.liveHUDPanelFactory = liveHUDPanelFactory
        self.inserter = inserterFactory()
    }

    /// Call exactly once, from `AppDelegate.applicationDidFinishLaunching` (mirrors
    /// `WindowManager.launch()`'s contract). Subscribes to `AppConfig.shared`'s
    /// `dictation.enabled` *and* `dictation.two_pass_decode` (design 31 §3.3: an
    /// `enabled`-only subscription would leave a Settings toggle of `two_pass_decode` unapplied --
    /// no batch warm on ON, no ~600MB release on OFF -- until the next restart or disable/enable
    /// cycle) so external `config.yaml` edits (`AppConfig`'s `watchForChanges: true`) are picked up
    /// automatically, and immediately applies the config's current values.
    func launch() {
        configCancellable = AppConfig.shared.$data
            .map { ($0.dictation.enabled, $0.dictation.twoPassDecode) }
            .removeDuplicates(by: ==)
            .sink { [weak self] enabled, twoPassDecode in
                self?.handleConfigChanged(enabled: enabled, twoPassDecode: twoPassDecode)
            }
    }

    // MARK: - Enablement (R3/R8, design 31 TP5/TP9)

    /// Not `private` (unlike the pre-design-31 `handleEnabledChanged`): `DictationControllerTwoPass
    /// Tests` drives the warm/release transitions directly without a real `AppConfig` subscription.
    func handleConfigChanged(enabled: Bool, twoPassDecode: Bool) {
        guard enabled else {
            state = .disabled
            transcriber = nil
            releaseBatchTranscriberIfNeeded()
            // design 32 HR5: a disable arriving mid-capture would otherwise leave the HUD (and its
            // ticker) up forever -- key-up's `guard state == .capturing` exits before its hide.
            liveHUDPanel?.hide()
            return
        }

        requestPermissionsIfNeeded()
        wireHotkeyIfNeeded()
        applyBatchDecodeEnablement(twoPassDecode: twoPassDecode)

        guard !isWarming, transcriber == nil else {
            if transcriber != nil {
                state = .idle
            }
            return
        }
        isWarming = true
        let config = Self.resolveSttEngineConfig(dictation: dictationConfigProvider(), stt: sttConfigProvider())
        Task { [weak self] in
            guard let self else { return }
            do {
                let built = try await self.transcriberFactory(config)
                self.transcriber = built
                self.isWarming = false
                // The config could have been disabled again while the (multi-second) model load
                // was in flight; only surface `.idle` if it's still wanted.
                if self.dictationConfigProvider().enabled {
                    self.state = .idle
                }
            } catch {
                self.isWarming = false
                self.logger.error("failed to warm the dictation STT backend: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The batch model's warm/release transitions (design 31 §3.3, `enabled == true` half):
    /// ON warms once (utterances confirm from the streaming raw until it lands, TP5), OFF releases
    /// the ~600MB resident model immediately (TP9). A load failure logs and leaves `nil` -- every
    /// subsequent utterance falls back to the streaming raw (TP2); the feature never blocks.
    ///
    /// Not `private`: `DictationControllerTwoPassTests` drives the ON-side transitions through this
    /// method directly rather than `handleConfigChanged(enabled:twoPassDecode:)`, whose
    /// `requestPermissionsIfNeeded()` would fire a real AX permission prompt inside a test run.
    func applyBatchDecodeEnablement(twoPassDecode: Bool) {
        guard twoPassDecode else {
            releaseBatchTranscriberIfNeeded()
            return
        }
        guard !isBatchWarming, batchTranscriber == nil else { return }
        isBatchWarming = true
        let language = Self.resolveSttEngineConfig(dictation: dictationConfigProvider(), stt: sttConfigProvider()).language
        Task { [weak self] in
            guard let self else { return }
            do {
                let built = try await self.batchTranscriberFactory(language)
                self.isBatchWarming = false
                // Same re-check as the streaming warm above: the (download-included) load may
                // outlive the configuration that requested it -- drop the result rather than
                // resurrecting a model the user just turned off (design 31 §3.3). Unlike the
                // pre-design-33 direct-ownership model, `built` now holds a `BatchAsrDecoderLease`
                // (design 33 MT7) that is only released by an explicit `releaseModel()` call --
                // `BatchAsrDecoderLease` has no `deinit`-based release, so simply letting `built`
                // fall out of scope here would leak the pool's refcount forever.
                let config = self.dictationConfigProvider()
                if config.enabled, config.twoPassDecode {
                    self.batchTranscriber = built
                } else {
                    self.releaseIfRealTranscriber(built)
                }
            } catch {
                self.isBatchWarming = false
                self.logger.error("failed to warm the dictation batch decoder, utterances will confirm from the streaming text: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Releases the pool lease held by `batchTranscriber` (if it is the real
    /// `DictationBatchTranscriber` adapter -- test fakes conforming to `DictationBatchTranscribing`
    /// hold no lease and are simply dropped) before clearing the field, so an ON->OFF toggle or a
    /// disable frees dictation's share of the warm decoder immediately (design 31 §3.3/TP9, design
    /// 33 MT7: refcount 0 -> immediate free, unaffected by any concurrently recording meeting on the
    /// same `AsrModelVersion`).
    private func releaseBatchTranscriberIfNeeded() {
        releaseIfRealTranscriber(batchTranscriber)
        batchTranscriber = nil
    }

    /// Shared cast-and-release step for both `releaseBatchTranscriberIfNeeded()`'s `nil`-out path
    /// and `applyBatchDecodeEnablement(twoPassDecode:)`'s warm-completion race (config flipped off
    /// while the load was in flight): test fakes conforming to `DictationBatchTranscribing` hold no
    /// pool lease and are simply dropped, only the real `DictationBatchTranscriber` adapter needs its
    /// lease released (design 33 MT7).
    private func releaseIfRealTranscriber(_ transcriber: (any DictationBatchTranscribing)?) {
        (transcriber as? DictationBatchTranscriber)?.releaseModel()
    }

    /// `dictation.language` falls back to `stt.language`, and `chunkMs` always follows `stt.chunk_ms`
    /// (R3: sharing the same tier as the meeting pipeline is what lets `SttSharedModelCoordinator`
    /// dedup the CoreML model load).
    static func resolveSttEngineConfig(dictation: DictationConfig, stt: SttConfig) -> SttEngineConfig {
        var config = SttEngineConfig()
        config.language = dictation.language.isEmpty ? stt.language : dictation.language
        config.chunkMs = stt.chunkMs
        return config
    }

    /// AX/mic permission requests (R8), fired once per enablement rather than at app launch.
    /// Neither request blocks hotkey registration -- an unauthorized state degrades to a no-op
    /// insert/capture (logged only), not a hard failure. Settings surfaces the AX grant state via
    /// `isAccessibilityTrusted` instead of a system notification (R8).
    private func requestPermissionsIfNeeded() {
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        isAccessibilityTrusted = trusted

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default:
            break
        }
    }

    private func wireHotkeyIfNeeded() {
        guard !isHotkeyWired else { return }
        isHotkeyWired = true
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
            self?.handleHotkeyDown()
        }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
            self?.handleHotkeyUp()
        }
    }

    // MARK: - Gesture (§4)
    //
    // `handleHotkeyDown()`/`handleHotkeyUp()`/`decodeBatchIfEnabled` live in
    // `DictationController+Gesture.swift` (split out for SwiftLint's 600-line file-length limit).

    /// General state-transition seam for `handleHotkeyDown()`/`handleHotkeyUp()` in
    /// `DictationController+Gesture.swift`: the `state` setter stays `private(set)` so nothing
    /// outside this type's own files can mutate it directly (`markRefining()` below is this same
    /// seam, kept as its own named method since `DictationController+Refine.swift` only ever needs
    /// that one transition).
    func setState(_ newState: DictationState) {
        state = newState
    }

    /// `state = .refining` seam for `refineForHistory` in `DictationController+Refine.swift`:
    /// the `state` setter stays `private(set)`, so the split-out file transitions through this
    /// instead (see `refiner` for the file-split rationale).
    func markRefining() {
        state = .refining
    }

    /// Test-only observability seam for the batch warm/release transitions (design 31 §3.3):
    /// `batchTranscriber` itself stays `private`, but `DictationControllerTwoPassTests` needs to
    /// assert "ON warms / OFF releases" without reaching into stored state.
    var isBatchDecoderWarm: Bool {
        batchTranscriber != nil
    }

    /// Test-only seam: sets exactly the state `handleHotkeyDown()` would have left behind at the
    /// instant `handleHotkeyUp()` is called, so `DictationControllerHistoryTests` can drive
    /// `handleHotkeyUp()`'s post-capture path directly without a real hotkey/mic.
    func simulateCapturing(
        transcriber: DictationTranscriber?,
        capturedTarget: FrontmostGuard.Target?,
        historyEntryHandle: DictationHistoryStore.EntryHandle? = nil,
        historyEntryRecordedAt: Date? = nil,
        capturedMicDeviceInfo: DictationMicDeviceResolver.MicDeviceInfo? = nil,
        batchTranscriber: (any DictationBatchTranscribing)? = nil,
        recordedSamples: [Float] = []
    ) {
        self.transcriber = transcriber
        self.capturedTarget = capturedTarget
        self.state = .capturing
        self.historyEntryHandle = historyEntryHandle
        self.historyEntryRecordedAt = historyEntryRecordedAt
        self.capturedMicDeviceInfo = capturedMicDeviceInfo
        self.batchTranscriber = batchTranscriber
        self.simulatedRecordedSamples = recordedSamples
        // design 32 §3.1: materialize the (injected) HUD exactly as `handleHotkeyDown()` would
        // have -- `handleHotkeyUp()` only optional-chains the stored `liveHUDPanel`, so without
        // this a test's spy factory would never be called and every HUD assertion would be vacuous.
        liveHUDPanelController().show()
    }

    // MARK: - Overlay panel (D2, R5/§3.6)

    /// `internal` (not `private`): called from `handleHotkeyUp()` (`+Gesture.swift`).
    func overlayPanelController() -> DictationOverlayPanelController {
        if let overlayPanel {
            return overlayPanel
        }
        let controller = DictationOverlayPanelController(inserter: inserter)
        overlayPanel = controller
        return controller
    }

    // MARK: - Live-preview HUD (§"ライブプレビューHUD", design 32)

    /// `internal` (not `private`): called from `handleHotkeyDown()` (`+Gesture.swift`).
    func liveHUDPanelController() -> any DictationLiveHUDPresenting {
        if let liveHUDPanel {
            return liveHUDPanel
        }
        let controller = liveHUDPanelFactory()
        liveHUDPanel = controller
        return controller
    }
}
