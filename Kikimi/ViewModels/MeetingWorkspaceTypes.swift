import Foundation

// MARK: - RecordingAudioCapturing / RecordingTranscriptPipelining

/// Abstraction over `AudioCapture`'s recording-lifecycle surface that `MeetingWorkspaceViewModel`
/// needs (`docs/design/06-ui-panels.md` section 6.1). Mirrors the `AudioSourceCapturing` DI pattern
/// (`docs/design/01-audio-capture.md` section 10, `Kikimi/AudioCapture/AudioCaptureTypes.swift`) so
/// unit tests can substitute a fake that fails deterministically, instead of depending on real
/// `AVAudioEngine`/ScreenCaptureKit permissions or hardware.
protocol RecordingAudioCapturing: AnyObject {
    /// Must be set by `startRecording()` before `start()` (see `TranscriptPipeline`'s documented
    /// call-order contract in `Kikimi/Stt/TranscriptPipeline.swift`, step ④:
    /// "audioCapture.delegate = transcriptPipeline (may happen any time before ③
    /// AudioCapture.start())"). Without this, `AudioCapture`'s captured PCM buffers never reach
    /// `TranscriptPipeline`'s `didCapture` handler, so no segment is ever transcribed even though
    /// the WAV files still record fine. Declared on this DI seam (not just on the concrete
    /// `AudioCapture`) so `startRecording()` can wire it through a fake in tests too.
    var delegate: AudioCaptureDelegate? { get set }
    func start() async throws
    func stop() async
}

extension AudioCapture: RecordingAudioCapturing {}

/// Abstraction over `TranscriptPipeline`'s recording-lifecycle surface that `MeetingWorkspaceViewModel`
/// needs (section 6.1/6.3). Same DI rationale as `RecordingAudioCapturing`: tests can substitute a
/// fake that fails/produces segments deterministically instead of depending on a real (possibly
/// not-installed) sherpa-onnx model.
///
/// Inherits `AudioCaptureDelegate` so a `RecordingTranscriptPipelining` value can be assigned to
/// `RecordingAudioCapturing.delegate` above — this existential upcast is exactly what wires
/// `AudioCapture`'s captured buffers into the pipeline (see `delegate`'s doc comment).
protocol RecordingTranscriptPipelining: AudioCaptureDelegate {
    func prepare(downloadProgress: (@Sendable (AudioSourceKind, SttModelDownloadProgress) -> Void)?) async throws
    func stopAndDrain() async
    var liveSegments: AsyncStream<TranscriptSegment> { get }

    /// Source-tagged, in-progress (unconfirmed) transcript text (`docs/design/11-streaming-stt.md`
    /// section 3.6). Replaces the previous batch-era `previewCleared` "clear signal" (which never
    /// carried text): streaming has real incremental text, so the Transcript タブ can now render each
    /// source's pending line live instead of only a "clear" pulse.
    var volatileTranscripts: AsyncStream<SttVolatileTranscript> { get }

    /// Forwards every `AudioCaptureDelegate.audioCapture(_:didDegrade:error:)` event this pipeline
    /// receives (`docs/design/10-audio-input-selection.md` section 5.2 / 8章 failure modes #7/#9).
    /// `TranscriptPipeline` itself only reacts to a degradation by stopping the affected source's
    /// `SttEngine` -- it has no UI-facing concept of a banner -- so without this callback,
    /// `AudioCapture`'s degradation events never reached `MeetingWorkspaceViewModel` at all (the gap
    /// this property closes). Set by the caller (`MeetingWorkspaceViewModel.startRecording()`) any
    /// time before `AudioCapture.start()` is invoked, mirroring `capture.delegate = pipeline`'s own
    /// ordering requirement. Invoked on `AudioCapture`'s `eventQueue` (not the main thread, per
    /// `AudioCaptureDelegate`'s own threading contract) -- callers must hop to `@MainActor`
    /// themselves.
    var onDegrade: (@Sendable (AudioSourceKind, AudioCaptureError) -> Void)? { get set }

    /// Forwards every `system`-source buffer this pipeline feeds to its `SttEngine`, in feed order
    /// (`docs/design/13-speaker-diarization.md` section 5; `TranscriptPipeline.onSystemAudio`'s doc
    /// comment). Set by `MeetingWorkspaceViewModel` to `RealtimeDiarizationCoordinator.feed(samples:)`
    /// whenever diarization is enabled for this recording segment (section 5.1 "入力選択との関係"); left
    /// `nil` otherwise, so this pipeline never has to know whether diarization exists at all.
    var onSystemAudio: (@Sendable ([Float]) async -> Void)? { get set }
}

extension TranscriptPipeline: RecordingTranscriptPipelining {}

// MARK: - RecordingButtonState

/// The state of the Session Window header's recording button, and by extension the
/// window's recording lifecycle phase. See `docs/design/06-ui-panels.md` section 5.3.
///
/// Shared between `MeetingWorkspaceWindowController` (which consults `blocksWindowClose` in
/// `windowShouldClose`, section 6.1.1) and `MeetingWorkspaceViewModel` (which owns the state
/// transitions driven by `startRecording()`/`stopRecording()` and by observing
/// `WindowManager.shared.$recordingSessionId`).
enum RecordingButtonState: Equatable {
    /// Draft. Button enabled, "● 録音開始".
    case startRecording
    /// `beginRecording`/`TranscriptPipeline.prepare`/`AudioCapture.start` are in flight.
    /// Button disabled, spinner shown.
    case starting
    /// This window is the one currently recording (kikimi.md 4 章). Buttons enabled: "■ 一時停止" /
    /// "⏹ 会議終了". `elapsedSeconds` is the cumulative recording-active time (closed segments'
    /// `durationMs` + the current segment's elapsed time), ticking every second.
    case recording(elapsedSeconds: Int)
    /// `pauseRecording`/`AudioCapture.stop`/`TranscriptPipeline.stopAndDrain` are in flight.
    /// Buttons disabled.
    case pausing
    /// Recording is stopped but the meeting is not confirmed done (kikimi.md 4 章 "一時停止").
    /// Buttons enabled: "● 録音再開" / "⏹ 会議終了". `elapsedSeconds` is the cumulative
    /// recording-active time frozen at the moment of pause (not ticking).
    case paused(elapsedSeconds: Int)
    /// Same as `.paused`, except a *different* session is currently Recording, so "● 録音再開" is
    /// disabled (kikimi.md 10 章: "他ウィンドウが Recording 中は、このウィンドウの `録音開始`/`録音再開` が
    /// disabled"). "⏹ 会議終了" stays enabled regardless — ending a Paused session never needs the
    /// recording-exclusivity claim (`SessionStore.endMeeting(_:)`'s `.paused` branch).
    case pausedDisabledOtherRecording(elapsedSeconds: Int, otherSessionId: String)
    /// `resumeRecording`/`reopenForRecording`/`TranscriptPipeline.prepare`/`AudioCapture.start` are
    /// in flight (resuming from Paused, or reopening from Ended). Buttons disabled, spinner shown.
    case resuming
    /// `endMeeting`/(if still Recording) `AudioCapture.stop`/`TranscriptPipeline.stopAndDrain` are
    /// in flight — the sole confirmation operation (kikimi.md 4 章 "会議終了"). Buttons disabled.
    case ending
    /// Another window is currently recording. Button disabled.
    case disabledOtherRecording(otherSessionId: String)
    /// Ended. Only the "↩ 再開" (救済) button is shown alongside the total-duration text.
    case ended

    /// `true` for every in-flight/active-recording-or-paused state; `false` otherwise. Both
    /// `windowShouldClose` (section 6.1.1) and the application-termination confirmation (section 9)
    /// consult this single property, so it must stay exhaustive over all cases. `.paused`/
    /// `.pausedDisabledOtherRecording` are included (kikimi.md 10 章 "Paused も「会議終了しますか」確認の
    /// 対象にする"): even though no audio capture is in flight, the meeting itself is not yet
    /// confirmed done, so closing the window still prompts the user to decide.
    var blocksWindowClose: Bool {
        switch self {
        case .recording, .starting, .pausing, .paused, .pausedDisabledOtherRecording, .resuming, .ending:
            return true
        case .startRecording, .disabledOtherRecording, .ended:
            return false
        }
    }

    /// `true` only for `.recording`/`.paused`/`.pausedDisabledOtherRecording` -- drives the header's
    /// "しまう"/"コンパクト表示" buttons (`docs/design/18-recording-window-stow-and-compact.md` §3.1).
    /// Deliberately narrower than `blocksWindowClose`, which also returns `true` for every in-flight
    /// transitional state (`.starting`/`.pausing`/`.resuming`/`.ending`): showing the stow controls
    /// during those transitions would let a user stow mid-`.starting`, so that a start failure then
    /// rolls back to a hidden Draft window (a `docs/design/18-...` §2 R2 violation that must be
    /// structurally impossible, §3.1/§6 #12/#13).
    var showsStowControls: Bool {
        switch self {
        case .recording, .paused, .pausedDisabledOtherRecording:
            return true
        case .startRecording, .starting, .pausing, .resuming, .ending, .disabledOtherRecording, .ended:
            return false
        }
    }

    /// The `elapsedSeconds` to display for this state, or `nil` for every state that doesn't carry
    /// one (`docs/design/18-recording-window-stow-and-compact.md` Major-1 fix). Only
    /// `.recording`/`.paused`/`.pausedDisabledOtherRecording` -- i.e. exactly the states
    /// `showsStowControls` above is also `true` for -- carry an `elapsedSeconds`; the transitional
    /// states in between (`.pausing`/`.resuming`) don't, since pause/resume are in-flight `await`s
    /// with no elapsed-time snapshot of their own.
    ///
    /// `CompactRecordingBarView`'s pill always reserves space for the elapsed-time label (unlike the
    /// normal header, which swaps in a `ProgressView` in place of the label during transitions) --
    /// without this accessor, its `elapsedText` had nothing but a hardcoded "00:00" fallback for
    /// `.pausing`/`.resuming`, so clicking pause/resume in the pill flashed the timer to zero for the
    /// duration of the await. Callers cache the last non-nil value across transitions instead.
    var elapsedSecondsForDisplay: Int? {
        switch self {
        case .recording(let elapsedSeconds), .paused(let elapsedSeconds):
            return elapsedSeconds
        case .pausedDisabledOtherRecording(let elapsedSeconds, _):
            return elapsedSeconds
        case .startRecording, .starting, .pausing, .resuming, .ending, .disabledOtherRecording, .ended:
            return nil
        }
    }
}

// MARK: - WorkspaceWindowMode

/// The Session Window's display mode: a full window, or a 380x44 compact pill
/// (`docs/design/18-recording-window-stow-and-compact.md` §3.4/§4.1). Owned by
/// `MeetingWorkspaceViewModel.windowMode`; `MeetingWorkspaceWindowController` observes it to drive
/// `applyWindowMode(_:)`, and `MeetingWorkspaceView` observes it to switch its root content between
/// `CompactRecordingBarView` and the normal header/tabs layout.
///
/// Deliberately **not** persisted to `state.yaml` (§4.1/R4: Recording never survives an app restart,
/// so every session always reopens `.normal` regardless of what it was compacted to before quitting).
enum WorkspaceWindowMode: Equatable, Sendable {
    case normal
    case compact
}

// MARK: - WorkspaceBanner

/// A dismissible, non-blocking banner surfaced in the Session Window header for failure/
/// progress conditions that shouldn't stop recording (kikimi.md section "録音は絶対に止めない").
/// See `docs/design/06-ui-panels.md` section 5.3.
enum WorkspaceBanner: Equatable, Identifiable {
    /// System audio capture is unavailable (e.g. missing permission), either at recording start
    /// (mic+system both enabled, system alone fails to start) or mid-recording (`SystemAudioSource
    /// .onDegraded`).
    ///
    /// `noActiveSourcesRemain` (`docs/design/10-audio-input-selection.md` section 5.2's wording-branch
    /// requirement) is `true` only when the microphone was disabled for this recording and system
    /// audio was the sole active source when it degraded -- i.e. recording continues writing silence
    /// with no active source left, and the existing "マイクのみで記録します" wording would be false.
    case systemAudioUnavailable(noActiveSourcesRemain: Bool)
    /// Writing the WAV file for the given source failed.
    case fileWriteFailed(source: AudioSourceKind)
    /// Writing to `transcript.jsonl` failed.
    case transcriptWriteFailed
    /// The STT model for the given source is still downloading.
    case sttModelDownloading(source: AudioSourceKind, progress: Double)
    /// The STT model download for the given source failed.
    case sttModelDownloadFailed(source: AudioSourceKind, message: String)
    /// Starting the recording sequence failed.
    case recordingStartFailed(message: String)
    /// System audio capture is enabled and the default output device is built-in speakers: acoustic
    /// leakage into the mic is likely (`docs/design/24-system-audio-leak-mitigation.md` §5.2).
    case builtInSpeakerOutputDetected
    /// `createDraftSession(seed: .profile(id: requestedProfileId))` could not resolve the requested
    /// meeting profile (invalid id / directory missing / broken `profile.yaml`), so the Draft was
    /// created with global defaults instead and `meta.profile_id` was left unset
    /// (`docs/design/41-meeting-profiles.md` §3.3/§4/§6.5). Surfaced by
    /// `WindowManager.createDraftWorkspace(seed:)` after opening the Session Window, not by
    /// `SessionStore` itself (`SessionStore` never touches any UI surface).
    case profileFallback(requestedProfileId: String)

    /// A stable identity per banner "kind" (and, where relevant, per `AudioSourceKind`).
    ///
    /// Deliberately excludes `progress` from `sttModelDownloading`: that value is expected to
    /// tick continuously while a single download is in flight, and if it were folded into `id`
    /// (e.g. via `String(describing: self)`), every tick would mint a new identity and thrash
    /// any `Identifiable`-driven UI (SwiftUI `List`/`ForEach`) rendering `banners` by recreating
    /// the row instead of updating it in place.
    var id: String {
        switch self {
        case .systemAudioUnavailable:
            return "systemAudioUnavailable"
        case .fileWriteFailed(let source):
            return "fileWriteFailed(\(source))"
        case .transcriptWriteFailed:
            return "transcriptWriteFailed"
        case .sttModelDownloading(let source, _):
            return "sttModelDownloading(\(source))"
        case .sttModelDownloadFailed(let source, _):
            return "sttModelDownloadFailed(\(source))"
        case .recordingStartFailed:
            return "recordingStartFailed"
        case .builtInSpeakerOutputDetected:
            return "builtInSpeakerOutputDetected"
        case .profileFallback(let requestedProfileId):
            return "profileFallback(\(requestedProfileId))"
        }
    }
}
