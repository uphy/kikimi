import Combine
import Foundation
import OSLog

// MARK: - MeetingWorkspaceViewModel
//
// `RecordingAudioCapturing`/`RecordingTranscriptPipelining` (the DI seams `startRecording()` uses
// for its `AudioCapture`/`TranscriptPipeline` collaborators) live in `MeetingWorkspaceTypes.swift`
// alongside this view model's other shared types — moved there to keep this file under the
// project's `file_length` lint limit.

/// Core view model for one Session Window window (`docs/design/06-ui-panels.md` sections 5.3,
/// 6.1, 6.2, 6.3; `docs/design/04-summary-updater.md` section 7; `docs/design/05-watcher-runner.md`
/// §10). Owns the header's recording state machine, the Prep tab's `context.md`/
/// `summary_template.md` editing and Watcher management, the Transcript tab's live-updating row
/// list, (via `+Summary.swift`) the Recording-scoped `SummaryUpdater` backing the Summary tab and
/// the title-proposal badge, and (via `+Watchers.swift`) the session-scoped `WatcherRunner` backing
/// the Watchers tab.
///
/// One instance per open session, vended by `WindowManager.shared` (section 5.2) and owned jointly
/// with `MeetingWorkspaceWindowController`. Never constructed by SwiftUI.
@MainActor
final class MeetingWorkspaceViewModel: ObservableObject {
    /// Constructs the `RecordingAudioCapturing` collaborator used by `startRecording()`/
    /// `resumeRecording()`/`reopenRecording()`, given the session's `audio/`-parent directory, the
    /// (already resolved, section 4 ②) `AudioInputSelection` to record with, and the recording
    /// segment index this instance writes `mic_NNN.wav`/`system_NNN.wav` for (kikimi.md 4 章).
    /// Injectable so tests never touch real `AVAudioEngine`/ScreenCaptureKit (see
    /// `defaultAudioCaptureFactory`).
    typealias AudioCaptureFactory = @MainActor (URL, AudioInputSelection, Int) -> RecordingAudioCapturing
    /// Constructs the `RecordingTranscriptPipelining` collaborator used by `startRecording()`/
    /// `resumeRecording()`/`reopenRecording()`, given the recording segment's `startMsOffset`
    /// (kikimi.md 5/6 章) so `TranscriptSegment.startMs`/`endMs` land on the cumulative timeline.
    /// Injectable so tests never depend on a real, possibly-not-installed sherpa-onnx model (see
    /// `defaultTranscriptPipelineFactory`).
    typealias TranscriptPipelineFactory = @MainActor (SessionHandle, Int) -> RecordingTranscriptPipelining
    /// Constructs the `SummaryUpdater` used while Recording (section 7 of the same doc). Injectable
    /// so tests inject a fake `LLMCompleting` (see `defaultSummaryUpdaterFactory`).
    typealias SummaryUpdaterFactory = @MainActor (SessionHandle) -> SummaryUpdater
    /// Constructs this session's `RefinementQueue` (`docs/design/03-refinement-batch.md` §3/§7),
    /// created at most once per `MeetingWorkspaceViewModel` instance
    /// (`MeetingWorkspaceViewModel+Refinement.swift`'s `refinementQueueIfNeeded()`, mirroring
    /// `diarizationCoordinatorIfEnabled()`'s one-instance-per-ViewModel guard). Injectable so tests
    /// inject a fake `LLMCompleting`/`RefinementConfig` (see `defaultRefinementQueueFactory`).
    typealias RefinementQueueFactory = @MainActor (SessionHandle) -> RefinementQueue
    /// Constructs this session's `RealtimeDiarizationCoordinator` (`docs/design/13-speaker
    /// -diarization.md` section 5: "`MeetingWorkspaceViewModel` がセッション単位で保持"), created at
    /// most once per instance (`diarizationCoordinatorIfEnabled()`). Injectable so tests drive
    /// diarization wiring with a fake, never a real LS-EEND model.
    typealias DiarizationCoordinatorFactory = @MainActor (SessionHandle) -> any DiarizationCoordinating
    /// Constructs the on-demand WAV voiceprint fallback extractor `applyRename(slot:submission:)` uses when a
    /// `.newName` rename's slot has no captured `embedding` yet (design section 4.4). Tests never touch a real file.
    typealias VoiceprintWavFallbackExtractorFactory = @MainActor (SessionHandle) -> any VoiceprintWavFallbackExtracting
    /// Constructs the Ended-time override-aggregate enrollment extractor (design 20's section 5.4 stage 2).
    typealias OverrideEnrollmentExtractorFactory = @MainActor (SessionHandle) -> any OverrideEnrollmentExtracting
    /// Constructs this session's `WatcherRunner` (`docs/design/05-watcher-runner.md` §9), created
    /// exactly once per `MeetingWorkspaceViewModel` instance at `init` time (unlike
    /// `refinementQueueFactory`'s lazy-on-first-recording-start pattern -- §9's "`WatcherRunner` の
    /// ライフサイクルは `MeetingWorkspaceViewModel` と同寿命", so `on_manual`/`on_session_end` work even for
    /// an Ended session that never records again). Injectable so tests inject a fake `LLMCompleting`
    /// (see `defaultWatcherRunnerFactory`).
    typealias WatcherRunnerFactory = @MainActor (SessionHandle) -> WatcherRunner
    // `docs/design/08-wiki-export.md`'s `WikiExporting` (the `wikiExporter` property below) has no
    // session-scoped lifecycle to construct, unlike every collaborator above -- it's injected
    // directly as a plain value (same DI shape as `voiceprintStore`/`inputEnumerator`), so no
    // `typealias`/factory is needed for it.

    let sessionId: String

    /// Not `private(set)`: `+Summary.swift` reloads this after `SummaryUpdater` events/title-adoption/
    /// regeneration (same rationale as `audioInputSelection` below).
    @Published var meta: SessionMeta
    /// `docs/design/17-session-window-redesign.md` §4.4/§4.5: whenever this changes, the Summary
    /// pane's visibility may have changed too, so `updateSummaryUnseenVisibility()` re-checks whether
    /// `summaryHasUnseenUpdate` should clear ("サマリペインが可視になった時... クリア"). This is the only
    /// side effect any `activeTab` write triggers -- every other consequence of a tab switch is pure
    /// SwiftUI re-rendering.
    @Published var activeTab: MeetingWorkspaceTab = .prep {
        didSet { updateSummaryUnseenVisibility() }
    }
    /// The `.meeting` tab's pane display mode (`docs/design/17-session-window-redesign.md` §4.2),
    /// persisted by `MeetingWorkspaceWindowController` alongside `activeTab`. Same
    /// `updateSummaryUnseenVisibility()` side effect as `activeTab` above -- narrowing away from
    /// `.transcript` (or broadening from it) can also change whether the Summary pane is visible.
    @Published var meetingPaneMode: MeetingPaneMode = .both {
        didSet { updateSummaryUnseenVisibility() }
    }
    /// `true` whenever `summaryMarkdown` was updated while the Summary pane wasn't visible
    /// (`docs/design/17-session-window-redesign.md` §4.4/§4.5), driving the "会議" tab's "サマリのみ表示"
    /// icon dot (`MeetingTabView`). Written from `+Summary.swift`'s `SummaryUpdater.events`
    /// subscription; cleared by `updateSummaryUnseenVisibility()` below the moment the pane becomes
    /// visible again.
    @Published var summaryHasUnseenUpdate: Bool = false
    /// Not `private(set)`: `+RecordingInternals.swift` (split out for `file_length`) drives most of
    /// this state machine's transitions from a separate file.
    @Published var recordingButtonState: RecordingButtonState = .startRecording
    @Published var banners: [WorkspaceBanner] = []
    /// `docs/design/18-...` §4.1: full window vs. compact pill. Never persisted (R4) -- always
    /// starts `.normal`; `MeetingWorkspaceWindowController` observes it to drive `applyWindowMode(_:)`.
    @Published var windowMode: WorkspaceWindowMode = .normal

    // Prep tab (section 6.2)
    @Published var contextText: String = ""
    @Published var summaryTemplateText: String = ""

    // Audio input selection (`docs/design/10-audio-input-selection.md` section 6.1). None of the
    // three are `private(set)`: the (not-yet-built) popover binds `audioInputSelection` directly for
    // Draft-time editing, and `MeetingWorkspaceViewModel+AudioInput.swift`'s `enumerateAudioInputs()`
    // writes the two arrays from a separate file.
    @Published var audioInputSelection: AudioInputSelection = .default
    @Published var availableInputDevices: [AudioDeviceInfo] = []
    @Published var availableSystemAudioApps: [AudioProcessInfo] = []

    // Transcript tab (section 6.3). Not `private(set)`: `+RecordingInternals.swift`'s
    // `startLiveSegmentSubscription(pipeline:)` writes this from a separate file.
    @Published var transcriptRows: [TranscriptRowViewModel] = []

    /// Bumped on each successful toolbar/⌘⇧C copy only, not per-row copies (design 37 §6/TC11); drives the toolbar checkmark swap. Not `private(set)`: `+Copy.swift` writes it.
    @Published var copyFeedbackToken: Int = 0
    /// Row id most recently copied via `copyRowMarkdown(rowId:)`, for that row's own checkmark feedback; `nil` after a toolbar copy.
    @Published var copyFeedbackRowId: String?

    /// Per-row speaker label (`docs/design/13-speaker-diarization.md` sections 5.3/6.1), keyed by
    /// `TranscriptRowViewModel.id`. Populated for every row (`mic` and `system`) only while
    /// `AppConfig.shared.data.diarization.enabled`; left empty when disabled, so a lookup miss always
    /// means "render the pre-diarization physical-source label" (design section 7, "false で本機能を
    /// 丸ごと無効化"). `mic` rows always resolve to `.named(diarizationConfig.selfName)` (design
    /// section 4.5); `system` rows are derived via `SpeakerLabelResolver` in
    /// `MeetingWorkspaceViewModel+Diarization.swift`, which owns every write to this property. Not
    /// `private(set)`: that extension file writes it from outside this file (same rationale as
    /// `transcriptRows` above).
    @Published var speakerLabels: [String: ResolvedSpeakerLabel] = [:]

    /// Summary tab live display (`docs/design/04-summary-updater.md` section 5.1/7): the latest
    /// rendered `summary.md`, pushed by `SummaryUpdater.events` (`+Summary.swift`). `nil` before the
    /// first update completes. Not `private(set)`: written from `+Summary.swift` (see `meta` above).
    @Published var summaryMarkdown: String?

    /// The transcript segment currently playing back through `segmentAudioPlayer`, `nil` when idle
    /// (`docs/design/15-segment-playback.md` section 6). Mirrors `SegmentAudioPlayer.playingSegmentId`
    /// so SwiftUI observes transitions -- kept in sync via the `onPlayingSegmentChanged` callback
    /// wired up in `init` below.
    @Published private(set) var playingSegmentId: String?

    /// Cumulative LLM token usage/cost for this session (`docs/design/16-llm-usage-stats.md`
    /// section 5), drives the header's cost badge. Not `private(set)`: `+LLMUsage.swift` writes
    /// this from a separate file (same rationale as `summaryMarkdown` above).
    @Published var llmUsageSummary: LLMUsageSummary = .empty

    /// Watchers tab data (`docs/design/05-watcher-runner.md` §10.1), rebuilt from `enabled.yaml` +
    /// each id's resolved definition and kept live via `watcherRunner.events`
    /// (`MeetingWorkspaceViewModel+Watchers.swift`). Ordered per `enabled.yaml`.
    @Published var watcherItems: [WatcherPanelItem] = []
    /// The Watchers tab's currently-selected sub-tab id (§10.1/§10.2), `nil` before the first
    /// `refreshWatcherItems()` call populates `watcherItems`.
    @Published var selectedWatcherId: String?
    /// A pending "jump to this segment" request from the Watchers tab's seg-id links (§10.4), consumed
    /// by `MeetingWorkspaceView`'s `TranscriptTabView` wiring (`scrollTarget`/`onScrollTargetConsumed`).
    @Published var pendingTranscriptScrollTarget: String?

    /// Source-tagged, in-progress (unconfirmed) transcript text (`docs/design/11-streaming-stt.md`
    /// section 3.6). Each stream fully replaces the previous value for its source; empty means
    /// "nothing pending" (never started, or just confirmed into `transcriptRows`). Not `private(set)`:
    /// written from `+VolatileTranscripts.swift` (same file-split rationale as `audioInputSelection`).
    @Published var micVolatileText: String = ""
    @Published var systemVolatileText: String = ""

    /// `internal` (not `private`) so `MeetingWorkspaceViewModel+Summary.swift` (split out for
    /// `file_length`, same rationale as `+Prep.swift`) can read/write through it directly.
    let sessionHandle: SessionHandle
    /// Not `private`: `+RecordingInternals.swift`'s `rollbackFailedSegmentStart(reason:previousState:)`
    /// calls `sessionStore.cancelRecordingStart(_:revertingTo:)` from a separate file.
    let sessionStore: SessionStore
    /// Not `private`: `MeetingWorkspaceViewModel+Recording.swift` (split out for `file_length`,
    /// same rationale as `+Summary.swift`) reads this to construct each recording segment's
    /// `AudioCapture`.
    let audioCaptureFactory: AudioCaptureFactory
    /// Not `private`: see `audioCaptureFactory`'s doc comment above.
    let transcriptPipelineFactory: TranscriptPipelineFactory
    /// Not `private`: `+Summary.swift` reads this to construct the Recording-scoped `SummaryUpdater`.
    let summaryUpdaterFactory: SummaryUpdaterFactory
    /// Not `private`: `MeetingWorkspaceViewModel+Refinement.swift` reads this to construct this
    /// session's `RefinementQueue` (`docs/design/03-refinement-batch.md` §3/§7).
    let refinementQueueFactory: RefinementQueueFactory
    /// Not `private`: `MeetingWorkspaceViewModel+AudioInput.swift` (split out for `file_length`,
    /// same rationale as `+Prep.swift`) enumerates/persists through these
    /// (`docs/design/10-audio-input-selection.md` section 6.1's DI list).
    let inputEnumerator: AudioInputEnumerating
    let appState: AppState
    /// Not `private`: `MeetingWorkspaceViewModel+Diarization.swift` reads `appConfig.data.diarization`
    /// (`docs/design/13-speaker-diarization.md` section 7) to gate the whole feature.
    let appConfig: AppConfig
    /// Not `private`: `MeetingWorkspaceViewModel+Diarization.swift` calls this the first time a
    /// coordinator is needed.
    let diarizationCoordinatorFactory: DiarizationCoordinatorFactory
    /// Not `private`: `+Rename.swift`'s `applyRename(slot:submission:)` registers new global speakers
    /// through this. Defaults to the production singleton; tests inject their own temp-file-backed
    /// instance so no test ever touches the real `~/.local/state/kikimi/voiceprints.json`.
    let voiceprintStore: VoiceprintStore
    /// Not `private`: `+Rename.swift`'s `scheduleVoiceprintWavFallbackEnrollment(slot:displayName:)`
    /// calls this the first time a `.newName` rename needs on-demand WAV extraction.
    let voiceprintWavFallbackExtractorFactory: VoiceprintWavFallbackExtractorFactory
    /// Not `private`: `+OverrideEnrollment.swift`'s `scheduleOverrideEnrollment(...)` calls this for
    /// Ended-time override-aggregate enrollment (`docs/design/20-voiceprint-misassignment-mitigation.md`
    /// section 5.4's stage 2).
    let overrideEnrollmentExtractorFactory: OverrideEnrollmentExtractorFactory
    /// Not `private`: `MeetingWorkspaceViewModel+Watchers.swift` reads this for the Prep tab's
    /// preset-library operations, independent of `watcherRunner`'s own (private) copy
    /// (`docs/design/05-watcher-runner.md` §3.2).
    let watcherLibrary: WatcherLibrary
    /// Not `private`: `MeetingWorkspaceViewModel+Watchers.swift` owns every read of this session's
    /// Watcher runner. Created once at `init` (unlike `refinementQueue`'s lazy-on-first-recording
    /// pattern) -- see `WatcherRunnerFactory`'s doc comment above.
    let watcherRunner: WatcherRunner
    /// `docs/design/08-wiki-export.md`'s session-end Wiki raw export (kikimi.md 11 章). Not `private`:
    /// `MeetingWorkspaceViewModel+Recording.swift`'s `endMeeting()` calls this once, right after
    /// `watcherRunner.run(trigger: .onSessionEnd)`.
    let wikiExporter: WikiExporting
    /// Clipboard write seam for `+Copy.swift` (`docs/design/37-transcript-markdown-copy.md` §3.3, TC10). Live copy never re-reads disk, so no `TranscriptMarkdownSource` here.
    let pasteboard: PasteboardWriting
    /// The wall clock every `recordingButtonState` elapsed-time derivation reads (see
    /// `+RecordingInternals.swift`'s `cumulativeElapsedSeconds(for:now:)`). Injectable so tests are
    /// not at the mercy of real time: `== .recording(elapsedSeconds: 0)` assertions used to flake
    /// whenever parallel test load pushed a second between segment start and the assertion.
    let now: @Sendable () -> Date
    /// `internal` (not `private`) so `MeetingWorkspaceViewModel+Prep.swift` — split out to keep this
    /// file under the project's `file_length` lint limit — can log through the same logger instance.
    let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "MeetingWorkspaceViewModel")
    /// Transcript-row playback (`docs/design/15-segment-playback.md`). One instance per session
    /// window, independent of the recording lifecycle -- playback is available in every window
    /// state (Draft/Recording/Paused/Ended) as long as there is at least one recorded WAV file.
    let segmentAudioPlayer = SegmentAudioPlayer()

    /// `docs/design/18-recording-window-stow-and-compact.md` §5.1/§5.4: invoked once, unconditionally,
    /// right after `endMeeting()` resets `windowMode` to `.normal`. `nil` in every test -- wired by
    /// `MeetingWorkspaceWindowController.init`, which alone decides whether to actually reveal the
    /// window (stowed/compact only, never mid close-confirmation, §5.1/§6 #12); this view model
    /// carries no window-visibility policy itself, only the seam.
    var onMeetingEnded: ((String) -> Void)?

    /// Not `private`: `MeetingWorkspaceViewModel+Recording.swift` (split out for `file_length`) owns
    /// every read/write of this whole Recording-segment state machine group, mirroring the
    /// `diarizationCoordinator` group's own "Not private" rationale below.
    var audioCapture: RecordingAudioCapturing?
    var transcriptPipeline: RecordingTranscriptPipelining?
    // Not `private`: `elapsedTimerTask`/`liveSegmentTask`/`recordingSessionIdCancellable` are
    // started/stopped from `+RecordingInternals.swift`; `volatileTranscriptTask` from
    // `+VolatileTranscripts.swift` (see `micVolatileText` above).
    var elapsedTimerTask: Task<Void, Never>?
    var liveSegmentTask: Task<Void, Never>?
    var volatileTranscriptTask: Task<Void, Never>?
    var recordingSessionIdCancellable: AnyCancellable?
    /// `.kikimiLLMUsageRecorded` subscription (`docs/design/16-llm-usage-stats.md` section 5),
    /// started by `+LLMUsage.swift`'s `startObservingLLMUsage()`.
    var llmUsageObservation: AnyCancellable?
    // Not `private`: `+Summary.swift` owns the lifecycle of both (section 4.1/7).
    var summaryUpdater: SummaryUpdater?
    var summaryEventsTask: Task<Void, Never>?
    /// Not `private`: `MeetingWorkspaceViewModel+Refinement.swift` (split out for `file_length`, same
    /// rationale as `+Summary.swift`) owns the lifecycle of both (`docs/design/03-refinement-batch.md`
    /// §7). Unlike `summaryUpdater`, this is **not** discarded on Paused -- see that file's
    /// `refinementQueueIfNeeded()` doc comment.
    var refinementQueue: RefinementQueue?
    var refinementEventsTask: Task<Void, Never>?
    // Not `private`: `+Diarization.swift` (split out for `file_length`, same rationale as
    // `+Summary.swift`) owns every read/write of this whole group (`docs/design/13-speaker
    // -diarization.md` section 5).
    /// This session's `RealtimeDiarizationCoordinator`, created lazily at most once per
    /// `MeetingWorkspaceViewModel` instance (`diarizationCoordinatorIfEnabled()`). `nil` when
    /// `AppConfig.shared.data.diarization.enabled == false`.
    var diarizationCoordinator: (any DiarizationCoordinating)?
    /// Every `DiarizationTurn` this coordinator has emitted so far this instance's lifetime, plus
    /// (once, at hydration) a backfill read of `diarization.jsonl` (design section 5.2: attribution
    /// needs the *whole* history, not just the newest turn).
    var diarizationTurns: [DiarizationTurn] = []
    /// Cached `speaker_assignments.json`, refreshed at hydration and on every `renameSlot(_:
    /// displayName:)` call (design section 4.3).
    var diarizationAssignments = SpeakerAssignments()
    /// The rename popover's known-speaker picker (`docs/design/13-speaker-diarization.md` section
    /// 4.4/6.1): every currently-registered global speaker, refreshed at `onAppear()` and again after
    /// `applyRename(slot:submission:)` registers a brand-new one. Left empty (not an error state) when
    /// diarization is disabled or the read fails -- free-text renaming still works either way.
    @Published var knownVoiceprintSpeakers: [VoiceprintSpeaker] = []
    /// Session participant roster for UI display (`docs/design/22-participant-hints.md` section 4.1).
    /// Not `private(set)` (Swift's `private` does not span files even within one type): every write
    /// happens in `+Participants.swift`, mirroring `knownVoiceprintSpeakers` above.
    @Published var participantHints: [ParticipantHintItem] = []
    /// An unresolved suggest-box submission (ambiguous name / registration failure, `+Participants.swift`),
    /// for the (P3) UI to surface. Cleared at the start of every `addParticipantHint(_:)` call.
    @Published var participantHintError: String?
    /// Wall-clock time each `system`-source row was confirmed into `transcriptRows`, keyed by row id
    /// (design section 5.3 rule 1's "セグメント確定から" anchor for the "(認識中…)" → "Speaker ?" grace
    /// period). Never populated for backfilled rows (a reopened session's historical rows have no live
    /// "just confirmed" moment to anchor to).
    var diarizationSegmentConfirmedAt: [String: Date] = [:]
    var diarizationTurnsTask: Task<Void, Never>?
    /// Consumes `diarizationCoordinator.assignmentUpdates` (design section 5, "R2" voiceprint
    /// auto-matching) for the rest of this ViewModel instance's lifetime -- the `assignmentUpdates`
    /// counterpart to `diarizationTurnsTask` above, started alongside it in
    /// `diarizationCoordinatorIfEnabled()` (`MeetingWorkspaceViewModel+Diarization.swift`).
    var diarizationAssignmentUpdatesTask: Task<Void, Never>?
    /// Periodic re-derivation while Recording, so a segment stuck `.recognizing` transitions to
    /// `.unknown` once `AttributionTuning.unattributedGraceMs` elapses even without a new turn
    /// arriving to trigger a recompute (design section 5.3 rule 1).
    var diarizationLabelTickTask: Task<Void, Never>?
    /// The most recently spawned on-demand WAV voiceprint fallback attempt (design section 4.4,
    /// "実装時の追記 2026-07-03"), stored (not discarded) so tests can `await` its `.value` instead of
    /// racing a fire-and-forget `Task`. A one-shot attempt expected to finish on its own, so no
    /// `deinit` cancellation is needed.
    var voiceprintWavFallbackTask: Task<Void, Never>?
    /// Every Ended-time override-aggregate enrollment `Task` spawned this instance's lifetime
    /// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 5.4's stage 2; one per
    /// identity resolved that Ended run), appended-not-replaced (unlike `voiceprintWavFallbackTask`,
    /// several can run concurrently) so tests can `await` every one's `.value`.
    var overrideEnrollmentTasks: [Task<Void, Never>] = []
    /// Stage 2 re-entrancy guard: identities with a `scheduleOverrideEnrollment` `Task` in flight.
    var pendingOverrideEnrollmentIdentities: Set<EnrollmentIdentity> = []
    /// `watcherRunner.events` subscription, started once from `onAppear()`
    /// (`MeetingWorkspaceViewModel+Watchers.swift`'s `startWatchersIfNeeded()`). Unlike
    /// `summaryEventsTask`/`refinementEventsTask`, this is never torn down on Pause/End -- it lives
    /// for the whole `MeetingWorkspaceViewModel` instance, matching `watcherRunner`'s own lifetime.
    var watcherEventsTask: Task<Void, Never>?

    /// `true` once `AudioCapture.stop()`/`TranscriptPipeline.stopAndDrain()` have actually completed
    /// for the *current* stop attempt. Lets a retried `pauseRecording()`/`endMeeting()` (section 11
    /// failure mode #3) skip re-invoking them and retry only `SessionStore.pauseRecording(_:)`/
    /// `endMeeting(_:)` -- recording data must never be touched twice, and those two calls are not
    /// documented as idempotent. Not `private`: `+Recording.swift` reads/writes this alongside
    /// `audioCapture`/`transcriptPipeline` above.
    var hasStoppedAudioAndTranscript = false

    /// `docs/design/24-system-audio-leak-mitigation.md` §5.1/§5.2 state, grouped into
    /// `OutputRouteBannerState` (`+OutputRoute.swift`) to keep this file under `file_length`.
    var outputRoute = OutputRouteBannerState()

    /// - Parameters:
    ///   - sessionHandle: The session this workspace shows. Ownership is shared with whatever vends
    ///     this view model (`WindowManager.shared.openWorkspace(sessionId:)`); this type never
    ///     creates or closes a `SessionHandle` itself.
    ///   - sessionStore: Injectable for testability, same pattern as `SessionHandle`'s own injectable
    ///     dependencies. Production call sites rely on the default and always get `SessionStore.shared`.
    ///   - audioCaptureFactory / transcriptPipelineFactory: Injectable seams for `startRecording()`'s
    ///     collaborators (see the two `typealias` docs above).
    ///   - summaryUpdaterFactory: Injectable seam for the Recording-scoped `SummaryUpdater` (section
    ///     7), same DI rationale as the two factories above.
    ///   - refinementQueueFactory: Injectable seam for this session's `RefinementQueue`
    ///     (`docs/design/03-refinement-batch.md` §3/§7), same DI rationale as `summaryUpdaterFactory`.
    ///   - inputEnumerator / appState: Injectable seams for audio input selection (section 6.1),
    ///     same DI pattern as the two factories above.
    ///   - appConfig / diarizationCoordinatorFactory: Injectable seams for
    ///     `docs/design/13-speaker-diarization.md` (section 5/7), same DI pattern as the above.
    ///   - voiceprintStore: Injectable seam for the rename popover's enrollment paths (section 4.4/6.1,
    ///     "R2"). Defaults to `VoiceprintStore.shared`; tests always inject a temp-file-backed instance.
    ///   - voiceprintWavFallbackExtractorFactory / overrideEnrollmentExtractorFactory: Injectable seams
    ///     for the on-demand WAV voiceprint fallback (section 4.4) and the Ended-time override-aggregate
    ///     enrollment extraction (`docs/design/20-voiceprint-misassignment-mitigation.md` section 5.4).
    ///     Tests always inject a fake.
    ///   - watcherLibrary / watcherRunnerFactory: Injectable seams for
    ///     `docs/design/05-watcher-runner.md` §3.2/§9. `watcherRunnerFactory(sessionHandle)` is
    ///     invoked synchronously right here in `init` (not lazily) -- see `WatcherRunnerFactory`'s
    ///     doc comment for why. Tests always inject a fake `LLMCompleting`-backed runner and a
    ///     temp-directory-backed library.
    ///   - wikiExporter: Injectable seam for `docs/design/08-wiki-export.md`'s `endMeeting()` hook.
    ///     Defaults to `defaultWikiExporter()`, a real `WikiExporter(appConfig: .shared)`. Tests must
    ///     always inject a fake -- the production default resolves a real path under the user's home
    ///     directory regardless of which `AppConfig` is injected (see `defaultWikiExporter()`'s doc).
    ///
    /// Deliberately a plain, synchronous, non-throwing initializer (not `async`): every known caller
    /// constructs this type and immediately reads `sessionId`/`meta.title` back synchronously, with no
    /// `await` at either call site. `sessionHandle.sessionId` is a `let`, safely readable without
    /// `await` from any isolation context; `meta` is a `var` on the `SessionHandle` actor and cannot
    /// be read synchronously, so `init` seeds it with a placeholder and kicks off
    /// `hydrateFromSessionHandle()` in the background to replace it moments later.
    init(
        sessionHandle: SessionHandle,
        sessionStore: SessionStore = .shared,
        audioCaptureFactory: @escaping AudioCaptureFactory = MeetingWorkspaceViewModel.defaultAudioCaptureFactory,
        transcriptPipelineFactory: @escaping TranscriptPipelineFactory = MeetingWorkspaceViewModel.defaultTranscriptPipelineFactory,
        summaryUpdaterFactory: @escaping SummaryUpdaterFactory = MeetingWorkspaceViewModel.defaultSummaryUpdaterFactory,
        refinementQueueFactory: @escaping RefinementQueueFactory = MeetingWorkspaceViewModel.defaultRefinementQueueFactory,
        inputEnumerator: AudioInputEnumerating = AudioInputEnumerator(),
        appState: AppState = .shared,
        appConfig: AppConfig = .shared,
        diarizationCoordinatorFactory: @escaping DiarizationCoordinatorFactory = MeetingWorkspaceViewModel.defaultDiarizationCoordinatorFactory,
        voiceprintStore: VoiceprintStore = .shared,
        voiceprintWavFallbackExtractorFactory: @escaping VoiceprintWavFallbackExtractorFactory = MeetingWorkspaceViewModel.defaultVoiceprintWavFallbackExtractorFactory,
        overrideEnrollmentExtractorFactory: @escaping OverrideEnrollmentExtractorFactory = MeetingWorkspaceViewModel.defaultOverrideEnrollmentExtractorFactory,
        watcherLibrary: WatcherLibrary = MeetingWorkspaceViewModel.defaultWatcherLibrary(),
        watcherRunnerFactory: @escaping WatcherRunnerFactory = MeetingWorkspaceViewModel.defaultWatcherRunnerFactory,
        wikiExporter: WikiExporting = MeetingWorkspaceViewModel.defaultWikiExporter(),
        pasteboard: PasteboardWriting = SystemPasteboard(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionHandle = sessionHandle
        self.sessionStore = sessionStore
        self.audioCaptureFactory = audioCaptureFactory
        self.transcriptPipelineFactory = transcriptPipelineFactory
        self.summaryUpdaterFactory = summaryUpdaterFactory
        self.refinementQueueFactory = refinementQueueFactory
        self.inputEnumerator = inputEnumerator
        self.appState = appState
        self.appConfig = appConfig
        self.diarizationCoordinatorFactory = diarizationCoordinatorFactory
        self.voiceprintStore = voiceprintStore
        self.voiceprintWavFallbackExtractorFactory = voiceprintWavFallbackExtractorFactory
        self.overrideEnrollmentExtractorFactory = overrideEnrollmentExtractorFactory
        self.watcherLibrary = watcherLibrary
        self.watcherRunner = watcherRunnerFactory(sessionHandle)
        self.wikiExporter = wikiExporter
        self.pasteboard = pasteboard
        self.now = now
        self.sessionId = sessionHandle.sessionId
        self.meta = Self.placeholderMeta(sessionId: sessionHandle.sessionId)

        segmentAudioPlayer.onPlayingSegmentChanged = { [weak self] segmentId in
            self?.playingSegmentId = segmentId
        }

        Task { [weak self] in
            await self?.hydrateFromSessionHandle()
        }
    }

    /// `docs/design/13-speaker-diarization.md` section 5: `diarizationCoordinator` (and its LS-EEND/
    /// WeSpeaker CoreML models) must not outlive this ViewModel. `diarizationTurnsTask`/
    /// `diarizationAssignmentUpdatesTask` are unstructured `Task`s that strong-capture the coordinator
    /// and loop `for await` over its streams forever unless cancelled. `refinementEventsTask` needs the
    /// same cancellation (`docs/design/03-refinement-batch.md` §7). Every other Recording-scoped task
    /// needs no equivalent cancellation: `windowShouldClose` blocks closing while Recording, so by the
    /// time this instance is deallocated, `finishStoppingCapture()` has already stopped them.
    deinit {
        diarizationTurnsTask?.cancel()
        diarizationAssignmentUpdatesTask?.cancel()
        refinementEventsTask?.cancel()
        watcherEventsTask?.cancel()
        // `docs/design/05-watcher-runner.md` §9: "`WatcherRunner` は `MeetingWorkspaceViewModel` と
        // 同寿命" -- `shutdown()` (ends `events`, cancels every `on_interval` loop `Task`) runs once
        // this instance itself is going away, mirroring `windowWillClose` -> `workspaceWindowDidClose`
        // dropping the last strong reference to this ViewModel. `shutdown()` is `async` and `deinit`
        // cannot `await`, so this captures the actor value itself (not `self`) into a detached-style
        // `Task` -- safe because `WatcherRunner` is a plain `Sendable` reference read from a `let`
        // stored property, not a re-entry into `self`.
        let runner = watcherRunner
        Task { await runner.shutdown() }
    }

    // MARK: - Lifecycle

    /// Called once the Session Window view appears (`MeetingWorkspaceView`'s `.task`).
    /// Backfills `transcriptRows` from `transcript.jsonl` (`SessionHandle.readTranscriptSegments()`),
    /// merges in `refined.jsonl` (`docs/design/03-refinement-batch.md` §6), and starts observing
    /// `WindowManager.shared.$recordingSessionId` so this window's `recordingButtonState` reflects
    /// whether some *other* session is currently recording (section 6.1/10.1).
    func onAppear() async {
        do {
            let segments = try await sessionHandle.readTranscriptSegments()
            transcriptRows = segments
                .map {
                    TranscriptRowViewModel(
                        id: $0.id,
                        startMs: $0.startMs,
                        endMs: $0.endMs,
                        speaker: $0.speaker,
                        rawText: $0.text,
                        state: .raw
                    )
                }
                .sorted { lhs, rhs in
                    lhs.startMs != rhs.startMs ? lhs.startMs < rhs.startMs : lhs.id < rhs.id
                }
        } catch {
            logger.error(
                "Failed to backfill transcript segments for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }

        // `docs/design/03-refinement-batch.md` §6: a reopened session must show its already-refined
        // rows immediately, not just newly-arriving ones -- `refinedText` present -> `.refined`,
        // present but `nil` -> `.refinedFailed`, no matching refined row -> stays `.raw`.
        do {
            let refinedSegments = try await sessionHandle.readRefinedSegments()
            transcriptRows = Self.mergeRefinedState(refinedSegments, into: transcriptRows)
        } catch {
            logger.error(
                "Failed to backfill refined segments for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }

        // Moved ahead of the backfills below (was after): both read `knownVoiceprintSpeakers`
        // synchronously with no later re-run of their own (design 23 §2.2/3.2's `speakerNames`,
        // design 22 §4.1's `namesById`), so this must land first to resolve current names.
        await refreshKnownVoiceprintSpeakers()

        // `docs/design/13-speaker-diarization.md` section 6.1: a reopened Paused/Ended session must
        // show its already-resolved speaker labels immediately, not just newly-arriving ones.
        await initializeSpeakerLabelsFromBackfill()
        // `docs/design/22-participant-hints.md` section 4.1: restore the participant roster at the
        // same point.
        await initializeParticipantHintsFromBackfill()

        // design section 20 §5.5: recovers any override enrollment stage 2 left incomplete.
        await recoverIncompleteOverrideEnrollmentsIfNeeded()

        // `docs/design/16-llm-usage-stats.md` section 5: show already-recorded cumulative cost
        // immediately, then keep it updated for as long as this window stays open.
        startObservingLLMUsage()
        await refreshLLMUsage()

        // `docs/design/05-watcher-runner.md` §10.1: subscribe to `watcherRunner.events` and render
        // every enabled Watcher's already-persisted `state.json` once (no LLM call), so a reopened
        // session's Watchers tab isn't blank until the next trigger fires.
        await startWatchersIfNeeded()

        subscribeToRecordingSessionId()
    }

    /// Called when the Session Window view disappears (`MeetingWorkspaceView`'s `.onDisappear`).
    /// Deliberately synchronous (not `async`), matching the SwiftUI `.onDisappear` callback shape.
    /// Only tears down the `WindowManager.$recordingSessionId` UI subscription — recording itself
    /// (`audioCapture`/`transcriptPipeline`/`elapsedTimerTask`/`liveSegmentTask`/`volatileTranscriptTask`)
    /// is left untouched, since closing/hiding a window must never stop an in-progress recording
    /// (kikimi.md 4 章 "ウィンドウを閉じても Recording は止めない", section 6.1). In practice a Recording window's close
    /// is itself blocked by `MeetingWorkspaceWindowController.windowShouldClose` (section 6.1.1)
    /// until `pauseRecording()`/`endMeeting()` completes, so this only ever needs to release the UI
    /// subscription. Also stops any in-progress segment playback (`docs/design/15-segment-playback.md`
    /// section 6) -- unlike recording, playback is a pure UI convenience with no reason to keep going
    /// once the window is gone.
    func onDisappear() {
        recordingSessionIdCancellable?.cancel()
        recordingSessionIdCancellable = nil
        segmentAudioPlayer.stop()
    }

    // MARK: - Private: init hydration

    private static func placeholderMeta(sessionId: String) -> SessionMeta {
        SessionMeta(
            id: sessionId,
            title: "",
            titleAutoGenerated: true,
            titleAutoNamedOnce: false,
            titleProposal: nil,
            state: .draft,
            createdAt: Date(),
            startedAt: nil,
            endedAt: nil,
            durationMs: 0,
            recordings: [],
            basedOnSession: nil,
            segmentCount: 0,
            refinedCount: 0,
            appVersion: ""
        )
    }

    /// Replaces the placeholder `meta`/empty `contextText`/`summaryTemplateText` seeded by `init`
    /// with the real values read from `sessionHandle` (a `var` actor property, unreadable
    /// synchronously from `init` — see `init`'s doc comment). Also derives the real initial
    /// `recordingButtonState` from `meta.state`, but only if nothing has driven
    /// `recordingButtonState` away from its `init`-time default yet (`startRecording()` etc. always
    /// wins if it raced ahead of this hydration).
    ///
    /// Also applies `docs/design/10-audio-input-selection.md` section 4 ①'s hydrate-time
    /// resolution via `hydrateAudioInputSelectionIfStillDefault()`
    /// (`MeetingWorkspaceViewModel+AudioInput.swift`), guarded by the same race pattern as
    /// `recordingButtonState` above (section 6.1).
    private func hydrateFromSessionHandle() async {
        let loadedMeta = await sessionHandle.meta
        meta = loadedMeta
        contextText = await sessionHandle.readContext()
        summaryTemplateText = await sessionHandle.readSummaryTemplate()
        if recordingButtonState == .startRecording {
            recordingButtonState = Self.initialRecordingButtonState(for: loadedMeta, now: now())
        }
        hydrateAudioInputSelectionIfStillDefault()

        // kikimi.md 4 章/8 章: a reopened Paused/Ended session must show whatever `summary.md` a
        // prior recording segment already rendered, not just newly-arriving updates --
        // `startSummaryUpdaterIfNeeded()` (only called when Recording actually (re)starts) is not
        // enough on its own, since Paused/Ended sessions never call it again. Missing/unreadable is
        // the normal case for a Draft session with no summary yet, so this is a silent no-op then.
        if summaryMarkdown == nil, let onDisk = try? await sessionHandle.readText(.summaryMarkdown), !onDisk.isEmpty {
            summaryMarkdown = onDisk
        }
    }

}

// `cumulativeElapsedSeconds(for:now:)` and `initialRecordingButtonState(for:now:)` moved to
// `+RecordingInternals.swift` to keep this file under the project's `file_length` lint limit
// (both `static func`s, so any extension file can host them).

// Split out to keep this file under the project's `file_length` lint limit:
// `+Recording.swift` (recording-segment state machine + `flushSessionHandle()`), `+RecordingInternals.swift`
// (recordingSessionId subscription/start-rollback/elapsed timer/live segment subscription),
// `+Factories.swift` (production factory defaults), `+VolatileTranscripts.swift` (volatile-transcript
// subscription), `+Summary.swift` (`renameTitle(_:)`/`isDraft`/`SummaryUpdater` lifecycle),
// `+Refinement.swift` (`RefinementQueue` lifecycle/`mergeRefinedState(_:into:)`), `+LLMUsage.swift`
// (`.kikimiLLMUsageRecorded` observation), `+Watchers.swift` (Watcher events/Prep-tab management),
// `+AudioInput.swift`/`+Prep.swift`, and `+Participants.swift` (participant roster, design 22 §4/3.2).
