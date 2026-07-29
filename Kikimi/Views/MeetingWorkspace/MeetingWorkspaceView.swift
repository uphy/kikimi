import AppKit
import SwiftUI

// MARK: - MeetingWorkspaceView

/// Root SwiftUI view for a Session Window window: the always-visible header (inline-editable
/// title, record button/elapsed time, banners) plus either the Draft-only preparation screen or the
/// 3-tab container (準備/会議/Watchers), per `docs/design/17-session-window-redesign.md` §3/§5.1
/// (supersedes `docs/design/06-ui-panels.md` sections 6/10's four-tab layout).
///
/// Hosted by `MeetingWorkspaceWindowController` (`docs/design/06-ui-panels.md` section 6.1.1),
/// which owns window-chrome concerns this view does not reproduce in SwiftUI: the native NSPanel
/// title bar/close button, and the `windowShouldClose` recording-in-progress confirmation flow.
///
/// Depends on `MeetingWorkspaceViewModel` (section 5.3) exactly as specified by the design
/// document; that type is implemented by a separate module and is not (re)defined here.
struct MeetingWorkspaceView: View {
    @ObservedObject var viewModel: MeetingWorkspaceViewModel

    /// `docs/design/18-...` §5.3: `.task`/`.onDisappear` stay on this outer `Group`, not inside the
    /// `if`/`else` -- a root-level branch would re-fire them on every compact <-> normal switch.
    var body: some View {
        Group {
            if viewModel.windowMode == .compact {
                CompactRecordingBarView(viewModel: viewModel)
            } else {
                normalContent
            }
        }
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
    }

    private var normalContent: some View {
        VStack(spacing: 0) {
            // Belt-and-suspenders against the recurring "書き起こしが一切できない" footgun: when the app
            // was launched with `KIKIMI_TEST_INPUT` (real mic replaced by a dummy WAV, `AudioCapture.swift`)
            // or `KIKIMI_STUB_LLM` (LLM stubbed), a leftover test-mode process looks exactly like a broken
            // build. An unmissable, non-dismissable badge makes that state visible at a glance. Shown only
            // when a test env var is actually set, so production never renders it.
            if let testModeMessage = TestModeIndicator.message {
                TestModeBanner(message: testModeMessage)
                Divider()
            }

            header

            Divider()

            if !viewModel.banners.isEmpty {
                bannerList
                Divider()
            }

            // §3.1/R1: Draft never shows a tab bar at all -- the dedicated preparation screen is
            // `PrepContentView` itself, embedding the Watchers management section inline
            // (`showsWatchersSection: true`) since there's no separate Watchers tab to hold it while
            // Draft. Every other state shows the 3-tab layout (§3.2).
            if viewModel.isDraft {
                prepContent(showsWatchersSection: true)
            } else {
                TabView(selection: $viewModel.activeTab) {
                    ForEach(MeetingWorkspaceTab.allCases) { tab in
                        tabContent(for: tab)
                            .tabItem { Text(tab.title) }
                            .tag(tab)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tabContent(for tab: MeetingWorkspaceTab) -> some View {
        switch tab {
        case .prep:
            // §3.2/R5: a dedicated Watchers tab exists once tabs are shown, so the "準備" tab itself
            // no longer embeds the Watchers management section (Draft's dedicated screen above does).
            prepContent(showsWatchersSection: false)
        case .meeting:
            // Wires the canonical `MeetingTabView` (`Kikimi/Views/MeetingWorkspace/MeetingTabView.swift`,
            // `docs/design/17-session-window-redesign.md` §5.3): the pane-mode switcher over the same
            // `TranscriptTabView`/`SummaryTabView` wiring the old separate Transcript/Summary tabs used
            // (moved here verbatim).
            MeetingTabView(
                paneMode: $viewModel.meetingPaneMode,
                summaryHasUnseenUpdate: viewModel.summaryHasUnseenUpdate,
                onCopy: { scope in Task { await viewModel.copyMarkdown(scope: scope) } },
                copyFeedbackToken: viewModel.copyFeedbackToken,
                transcriptContent: { transcriptTabView },
                summaryContent: { summaryTabView }
            )
        case .watchers:
            // Wires the canonical `WatchersTabView` (`Kikimi/Views/MeetingWorkspace/WatchersTabView.swift`,
            // `docs/design/05-watcher-runner.md` §10.2, `docs/design/17-session-window-redesign.md`
            // §5.4). Also carries the Watcher management closures (§5.4/R5) `PrepContentView`'s Draft
            // screen wires the exact same way below.
            WatchersTabView(
                items: viewModel.watcherItems,
                selectedWatcherId: $viewModel.selectedWatcherId,
                onRunNow: { id in viewModel.runWatcherNow(id: id) },
                onOpenSegment: { segId in viewModel.jumpToTranscriptSegment(segId) },
                onSetWatcherEnabled: { id, enabled in viewModel.setWatcherEnabled(id: id, enabled: enabled) },
                onForkPresetWatcher: { id in await viewModel.forkPresetWatcher(id: id) },
                presetExists: { id in viewModel.presetExists(id: id) },
                onPromoteWatcherToPreset: { id in await viewModel.promoteWatcherToPreset(id: id) },
                onCreateLocalWatcher: { id in try await viewModel.createLocalWatcher(id: id) },
                onDeleteLocalWatcher: { id in await viewModel.deleteLocalWatcher(id: id) },
                availablePresets: { viewModel.availablePresets() },
                loadWatcherDefinitionText: { id in await viewModel.watcherDefinitionText(id: id) },
                onSaveLocalWatcherText: { id, text in await viewModel.saveLocalWatcherText(id: id, text: text) },
                loadSimpleWatcherSpec: { id in await viewModel.simpleWatcherSpec(id: id) },
                onCreateSimpleWatcher: { draft in try await viewModel.createSimpleWatcher(draft) },
                onUpdateSimpleWatcher: { id, draft in try await viewModel.updateSimpleWatcher(id: id, draft) },
                onConvertSimpleWatcherToFull: { id in try await viewModel.convertSimpleWatcherToFull(id: id) }
            )
        case .chat:
            // `docs/design/38-session-chat.md` §3.5. Available from Recording onward, like every
            // other tab -- Draft shows no tab bar at all (§3.1/CH1), and there is nothing to ask
            // about before a single line has been transcribed.
            ChatTabView(
                turns: viewModel.chatTurns,
                draft: $viewModel.chatDraft,
                isResponding: viewModel.isChatResponding,
                copyFeedbackTurnId: viewModel.chatCopyFeedbackTurnId,
                onSend: { Task { await viewModel.sendChatMessage() } },
                onRetry: { id in Task { await viewModel.retryChatTurn(id: id) } },
                onCopy: { id in viewModel.copyChatAnswer(id: id) }
            )
        }
    }

    /// Wires the canonical `PrepContentView` (`Kikimi/Views/MeetingWorkspace/PrepContentView.swift`,
    /// renamed from `PrepTabView`), which owns the full "他セッションから複製…" flow via
    /// `duplicatePrepFiles(from:scope:)`. Shared by both call sites above (Draft's dedicated screen
    /// and the "準備" tab) so their identical closures aren't duplicated. See the removed-duplicate
    /// note near the bottom of this file: this file previously shadowed it with a local `private
    /// struct PrepTabView` that hard-disabled that button.
    private func prepContent(showsWatchersSection: Bool) -> some View {
        PrepContentView(
            sessionId: viewModel.sessionId,
            contextText: $viewModel.contextText,
            summaryTemplateText: $viewModel.summaryTemplateText,
            onContextChange: { text in Task { await viewModel.saveContext(text) } },
            onSummaryTemplateChange: { text in Task { await viewModel.saveSummaryTemplate(text) } },
            duplicatePrepFiles: { sourceSessionId, scope in
                await viewModel.duplicatePrepFiles(from: sourceSessionId, scope: scope)
            },
            // `docs/design/22-participant-hints.md` §5: the "参加者" section appears at both `prepContent`
            // call sites (Draft's dedicated screen and the "準備" tab) identically -- unlike the Watchers
            // management section above, it does not vary with `showsWatchersSection`.
            participantHints: viewModel.participantHints,
            knownSpeakers: viewModel.knownVoiceprintSpeakers,
            participantHintError: viewModel.participantHintError,
            onAddParticipant: { submission in Task { await viewModel.addParticipantHint(submission) } },
            onRemoveParticipant: { id in Task { await viewModel.removeParticipantHint(id: id) } },
            // §5.2 B-2: the persistence-lag hint is shown only while this session is actively
            // Recording/Paused -- `blocksWindowClose` already answers exactly that question (see
            // `PrepContentView.isRecordingActive`'s own doc comment for why this property, not a new
            // one, is the right fit).
            isRecordingActive: viewModel.recordingButtonState.blocksWindowClose,
            showsWatchersSection: showsWatchersSection,
            watcherItems: viewModel.watcherItems,
            onSetWatcherEnabled: { id, enabled in viewModel.setWatcherEnabled(id: id, enabled: enabled) },
            onForkPresetWatcher: { id in await viewModel.forkPresetWatcher(id: id) },
            presetExists: { id in viewModel.presetExists(id: id) },
            onPromoteWatcherToPreset: { id in await viewModel.promoteWatcherToPreset(id: id) },
            onCreateLocalWatcher: { id in try await viewModel.createLocalWatcher(id: id) },
            onDeleteLocalWatcher: { id in await viewModel.deleteLocalWatcher(id: id) },
            availablePresets: { viewModel.availablePresets() },
            loadWatcherDefinitionText: { id in await viewModel.watcherDefinitionText(id: id) },
            onSaveLocalWatcherText: { id, text in await viewModel.saveLocalWatcherText(id: id, text: text) },
            loadSimpleWatcherSpec: { id in await viewModel.simpleWatcherSpec(id: id) },
            onCreateSimpleWatcher: { draft in try await viewModel.createSimpleWatcher(draft) },
            onUpdateSimpleWatcher: { id, draft in try await viewModel.updateSimpleWatcher(id: id, draft) },
            onConvertSimpleWatcherToFull: { id in try await viewModel.convertSimpleWatcherToFull(id: id) }
        )
    }

    /// Wires the canonical `TranscriptTabView` (`Kikimi/Views/MeetingWorkspace/TranscriptTabView.swift`),
    /// which owns the bottom-anchor-based auto-follow scrolling and the empty-state placeholder.
    /// `speakerLabels`/`selfName`/`resolveSlot`/`onRenameSlot` wire `docs/design/13-speaker
    /// -diarization.md` section 6.1's staged speaker label + rename popover: `resolveSlot` reads
    /// `viewModel.speakerLabels[row.id]?.attributedSlots` -- the raw `spk_N` id(s)
    /// `SpeakerLabelResolver.resolve(...)` already derived while computing the label itself
    /// (`ResolvedSpeakerLabel.attributedSlots`'s doc comment) -- rather than calling
    /// `SegmentAttribution.attribute(...)` again here on every render. Doing that recomputation here
    /// used to be part of a real CPU-pinning/UI-freeze bug: `viewModel.diarizationTurns` grows
    /// unboundedly over a long recording, and this closure ran once per row on every SwiftUI body
    /// re-evaluation (including scroll-triggered ones), not just when diarization data actually
    /// changed. Embedded by `MeetingTabView` (`docs/design/17-session-window-redesign.md` §5.3),
    /// unchanged from the old standalone Transcript tab's wiring.
    private var transcriptTabView: some View {
        TranscriptTabView(
            rows: viewModel.transcriptRows,
            micVolatileText: viewModel.micVolatileText,
            systemVolatileText: viewModel.systemVolatileText,
            speakerLabels: viewModel.speakerLabels,
            knownSpeakers: viewModel.knownVoiceprintSpeakers,
            selfName: viewModel.appConfig.data.diarization.selfName,
            renameTargets: { row in
                guard row.speaker == .system else { return [] }
                let slots = viewModel.speakerLabels[row.id]?.attributedSlots ?? []
                let assignments = viewModel.diarizationAssignments
                return slots.map { slot in
                    let name = assignments.assignments[slot]?.displayName
                    return RenameableSlot(
                        slot: slot,
                        title: SpeakerLabelResolver.displayString(forSlot: slot, assignments: assignments),
                        currentName: (name?.isEmpty == false) ? name : nil,
                        embedding: assignments.assignments[slot]?.embedding,
                        assignedBy: assignments.assignments[slot]?.assignedBy
                    )
                }
            },
            onRenameSlot: { slot, submission in
                await viewModel.applyRename(slot: slot, submission: submission)
            },
            onOverrideSegment: { segmentId, submission in
                await viewModel.overrideSegmentSpeaker(segmentId: segmentId, submission: submission)
            },
            playingRowId: viewModel.playingSegmentId,
            onTogglePlayback: { row in viewModel.toggleSegmentPlayback(row) },
            onCopyRow: { row in Task { await viewModel.copyRowMarkdown(rowId: row.id) } },
            copyFeedbackRowId: viewModel.copyFeedbackRowId,
            scrollTarget: viewModel.pendingTranscriptScrollTarget,
            onScrollTargetConsumed: { viewModel.pendingTranscriptScrollTarget = nil }
        )
    }

    /// Wires the canonical `SummaryTabView` (`Kikimi/Views/MeetingWorkspace/SummaryTabView.swift`).
    /// `docs/design/04-summary-updater.md` section 5.1: a live view over `viewModel.summaryMarkdown`
    /// (pushed by `SummaryUpdater.events`) instead of a one-shot `sessionHandle.readText(
    /// .summaryMarkdown)` snapshot. Embedded by `MeetingTabView`
    /// (`docs/design/17-session-window-redesign.md` §5.3), unchanged from the old standalone Summary
    /// tab's wiring.
    private var summaryTabView: some View {
        SummaryTabView(
            summaryMarkdown: viewModel.summaryMarkdown,
            onRegenerate: { await viewModel.regenerateSummary() }
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            titleView
            // `docs/design/04-summary-updater.md` section 3.2/`06-ui-panels.md` section 6.1: the
            // "新しいタイトル案: XX [採用]" proposal badge. `titleProposal` is only ever non-nil while
            // `titleAutoGenerated == true` (`SummaryUpdater`'s own gating, section 3.1/3.4), but this
            // is checked again here as a defensive double-guard per the design note.
            if viewModel.meta.titleAutoGenerated, let proposal = viewModel.meta.titleProposal {
                TitleProposalBadge(proposal: proposal) {
                    Task { await viewModel.adoptTitleProposal() }
                }
            }
            Spacer()
            // `docs/design/16-llm-usage-stats.md` section 5: hidden until at least one LLM call has
            // been recorded for this session, so a freshly-opened Draft window's header doesn't show
            // a "$0.0000" badge with nothing behind it.
            if viewModel.llmUsageSummary.overall.callCount > 0 {
                LLMUsageBadge(summary: viewModel.llmUsageSummary)
            }
            // docs/design/10-audio-input-selection.md section 7.1: hidden once Ended (there is
            // nothing left to configure for a finished recording); shown and editable in every
            // other state, including `.disabledOtherRecording` (preparing this window's *next*
            // recording is legitimate even while another window is recording).
            if viewModel.recordingButtonState != .ended {
                AudioInputPopoverButton(viewModel: viewModel)
            }
            if viewModel.recordingButtonState.showsStowControls { // §3.1: Recording/Paused only
                StowControlButtonsView(viewModel: viewModel)
            }
            recordingControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Banners

    private var bannerList: some View {
        VStack(spacing: 6) {
            ForEach(viewModel.banners) { banner in
                WorkspaceBannerRow(banner: banner) {
                    // `docs/design/24-system-audio-leak-mitigation.md` §5.2: dismissing this banner
                    // also latches `dismissedBuiltInSpeakerBanner` so `OutputRouteMonitor` re-evaluations
                    // don't resurrect it for the rest of this session window's lifetime.
                    if case .builtInSpeakerOutputDetected = banner {
                        viewModel.dismissBuiltInSpeakerBanner()
                    } else {
                        viewModel.banners.removeAll { $0.id == banner.id }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Title editing

private struct MeetingWorkspaceTitleView: View {
    @ObservedObject var viewModel: MeetingWorkspaceViewModel
    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 4) {
            if isEditing {
                TextField("タイトル", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .onSubmit(commit)
                    .onExitCommand { isEditing = false }
            } else {
                Text(viewModel.meta.title.isEmpty ? "無題の会議" : viewModel.meta.title)
                    .font(.headline)
                    .lineLimit(1)
                Button {
                    draft = viewModel.meta.title
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                // AX contract for `kikimi-verify`/System Events scripting: `.help` is what
                // AppleScript's `get help of button` reads, `.accessibilityLabel` covers AX API
                // consumers that read the name instead. Keep both in sync with this exact string.
                .help("タイトルを編集")
                .accessibilityLabel("タイトルを編集")
            }
        }
    }

    private func commit() {
        isEditing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != viewModel.meta.title else { return }
        Task { await viewModel.renameTitle(trimmed) }
    }
}

private extension MeetingWorkspaceView {
    var titleView: some View {
        MeetingWorkspaceTitleView(viewModel: viewModel)
    }
}

// MARK: - Title proposal badge (kikimi.md 8 章 "自動タイトル命名"; `docs/design/04-summary-updater.md`
// section 3.2/3.4)

/// "新しいタイトル案: XX [採用]" -- shown whenever `SummaryUpdater` has a pending title proposal
/// (either a Recording-time re-proposal after the once-only auto-reflect, or the session-end final
/// title). Deliberately understated (`.secondary`/`.callout`) per `06-ui-panels.md` section 6.1's
/// "控えめに表示".
private struct TitleProposalBadge: View {
    let proposal: String
    let onAdopt: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("新しいタイトル案: \(proposal)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("採用", action: onAdopt)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                // AX contract for `kikimi-verify`/System Events scripting: the visible label is
                // just "採用", but the button's AX name/help is disambiguated to "タイトル案を採用"
                // so scripts can find it without depending on positional header indexes.
                .help("タイトル案を採用")
                .accessibilityLabel("タイトル案を採用")
        }
    }
}

// MARK: - Recording control
//
// `RecordingControlView` (the switch over `viewModel.recordingButtonState`) and this view's own
// `recordingControl` computed property live in `RecordingControlView.swift` now (moved out for the
// same `file_length`-lint reason noted at that file's own top-of-file doc comment).

// MARK: - WorkspaceBannerRow

/// Renders one `WorkspaceBanner` with the user-visible message text from
/// `docs/design/06-ui-panels.md` section 11 (failure mode table).
private struct WorkspaceBannerRow: View {
    let banner: WorkspaceBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15))
        .cornerRadius(6)
    }

    private var message: String {
        switch banner {
        case .systemAudioUnavailable(let noActiveSourcesRemain):
            // `docs/design/10-audio-input-selection.md` section 5.2: when the microphone was disabled
            // for this recording and system audio was the sole active source, "マイクのみで記録します"
            // would be false -- recording continues writing silence with nothing left transcribing.
            return noActiveSourcesRemain
                ? "システム音声が停止しました。録音を停止して確認してください"
                : "システム音声を取得できません。マイクのみで記録します。"
        case .fileWriteFailed(let source):
            return "\(Self.label(for: source))の音声ファイルの書き込みに失敗しました。"
        case .transcriptWriteFailed:
            return "書き起こしの保存に失敗しました。"
        case .sttModelDownloading(let source, let progress):
            return "\(Self.label(for: source))の音声認識モデルをダウンロード中です…（\(Int(progress * 100))%）"
        case .sttModelDownloadFailed(let source, let message):
            return "\(Self.label(for: source))の音声認識モデルのダウンロードに失敗しました: \(message)"
        case .recordingStartFailed(let message):
            return "録音を開始できませんでした: \(message)"
        case .builtInSpeakerOutputDetected:
            return "内蔵スピーカーで会議音声を再生していると、マイクが音を拾って二重に書き起こされることがあります。イヤホン/ヘッドホンの使用をお勧めします"
        }
    }

    private static func label(for source: AudioSourceKind) -> String {
        switch source {
        case .mic: return "マイク"
        case .system: return "システム音声"
        }
    }
}

// MARK: - Removed-duplicate note
//
// `SummaryTabView`/`TranscriptTabView`/`PrepTabView`/`WatchersTabView` are all implemented in their
// own files under `Kikimi/Views/MeetingWorkspace/`, per `docs/design/06-ui-panels.md` section 6.4.
// This file used to shadow every one of them (plus `PlainTextEditor`, `Kikimi/Views/
// PlainTextEditor.swift`) with local `private` duplicates of the identical name. Swift's file-scoped
// `private` lets a same-named top-level type coexist with an unrelated internal type of the same
// name declared in another file (no redeclaration error), so the duplication compiled silently but
// made `tabContent(for:)` above always resolve to this file's own (inferior/incomplete) copy instead
// of the real implementation — e.g. the local `PrepTabView` hard-disabled "他セッションから複製…"
// even though `PrepTabView.swift` already implements that flow via `duplicatePrepFiles(from:scope:)`.
// All of those duplicates, including a `SummaryTabPlaceholder` that stood in for `SummaryTabView`
// while `sessionHandle` wasn't yet exposed by the view model, have been removed in favor of wiring
// the shared views directly above.

// MARK: - TimeFormatting

/// Pure time-formatting helper for the header's elapsed/total-duration display.
/// See `docs/design/06-ui-panels.md` section 6.1.
///
/// The Transcript tab's per-row `HH:MM:SS` timestamp used to be formatted by a second helper here
/// (`timestamp(forMs:)`), but that was only ever called by this file's now-removed local duplicate
/// of `TranscriptRowView`; the canonical `TranscriptTabView.swift` has its own equivalent
/// `formattedTimestamp(startMs:)`, so it was dropped rather than left as dead code.
enum TimeFormatting {
    /// `MM:SS`, or `H:MM:SS` once the duration reaches an hour. Used for the header's recording
    /// elapsed-time / Ended total-duration display (kikimi.md 10 章 header mockup, e.g. "25:12").
    static func clock(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
