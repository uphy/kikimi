import SwiftUI

// MARK: - CompactTicker

/// Pure helper for the compact bar's one-line transcript ticker
/// (`docs/design/18-recording-window-stow-and-compact.md` §3.4/§5.3), factored out so its priority
/// logic is directly unit-testable without any SwiftUI/AppKit dependency -- the same pattern
/// `TranscriptRowList` (`Kikimi/ViewModels/TranscriptRowList.swift`) already uses for its own pure
/// core.
enum CompactTicker {
    /// Priority order (§5.3): the trailing line of whichever stream currently has one -- its
    /// confirming text (already confirmed, row not back from the two-pass re-decode yet) followed by
    /// its in-progress volatile text, mic checked first and system second (a deterministic tie-break
    /// for the rare case both are simultaneously non-empty, since this pure function has no timestamp
    /// to resolve "which one updated most recently" from) -- then the last confirmed transcript row
    /// (`refined ?? raw`, skipping rows refinement dropped as meaningless or folded into an earlier
    /// row's merge -- `docs/design/03-refinement-batch.md` §15.2.6), then `nil` (nothing to show yet;
    /// the caller renders a placeholder).
    ///
    /// Including the confirming text is what stops the ticker from jumping *backwards* to the
    /// previous row for the ~1.15s (25s window, `docs/design/45-qwen3-batch-decode.md`) between a
    /// segment confirming and its row arriving -- the compact-bar counterpart of the Transcript タブ's
    /// own trailing line (`TranscriptVolatileRowContentView`).
    ///
    /// - Parameters:
    ///   - rows: `TranscriptRowViewModel`s in `MeetingWorkspaceViewModel.transcriptRows`' own order
    ///     (`start_ms` ascending, per `TranscriptRowList.inserted(_:into:)`) -- the last element is
    ///     the most recently confirmed row.
    ///   - micVolatileText: `MeetingWorkspaceViewModel.micVolatileText`. Empty means "nothing
    ///     pending" (never started, or just confirmed into `rows`).
    ///   - systemVolatileText: `MeetingWorkspaceViewModel.systemVolatileText`, same convention.
    ///   - micConfirmingText: `MeetingWorkspaceViewModel.micConfirmingText`. Empty means "no
    ///     confirmed text is currently in flight toward a row" for that source.
    ///   - systemConfirmingText: `MeetingWorkspaceViewModel.systemConfirmingText`, same convention.
    static func text(
        rows: [TranscriptRowViewModel],
        micVolatileText: String,
        systemVolatileText: String,
        micConfirmingText: String = "",
        systemConfirmingText: String = ""
    ) -> String? {
        let mic = micConfirmingText + micVolatileText
        if !mic.isEmpty {
            return mic
        }
        let system = systemConfirmingText + systemVolatileText
        if !system.isEmpty {
            return system
        }

        for row in rows.reversed() {
            if row.state.isDroppedByRefinement || row.state.isMergedAway {
                continue
            }
            switch row.state {
            case .refined(let refinedText):
                return refinedText
            case .raw, .refining, .refinedFailed:
                return row.rawText
            case .mergedInto:
                continue // Unreachable (already filtered by isMergedAway above); keeps the switch exhaustive.
            }
        }

        return nil
    }
}

// MARK: - CompactRecordingBarView

/// The 380x44 pill `MeetingWorkspaceView` renders in place of the normal header/tabs layout while
/// `viewModel.windowMode == .compact` (`docs/design/18-recording-window-stow-and-compact.md` §3.4).
/// Deliberately minimal (§3.4's "入れないもの"): no `⏹ 会議終了`, no tabs/banners list, no title
/// editing/proposal badge, no `AudioInputPopoverButton` -- all of those require expanding first.
struct CompactRecordingBarView: View {
    @ObservedObject var viewModel: MeetingWorkspaceViewModel

    /// Cache of the last non-nil `recordingButtonState.elapsedSecondsForDisplay`
    /// (`docs/design/18-recording-window-stow-and-compact.md` Major-1 fix): `.pausing`/`.resuming`
    /// don't carry an `elapsedSeconds` of their own (they're in-flight `await`s), so without this
    /// cache `elapsedText`'s `default` branch had nothing to fall back to but a hardcoded "00:00" --
    /// clicking pause/resume in the pill flashed the timer to zero for the duration of the await.
    /// `@State` (not a `MeetingWorkspaceViewModel` property) because this is purely a rendering
    /// concern of this one view: the normal header never hits the same gap, since it swaps in a
    /// `ProgressView` in place of the elapsed-time label during those same transitions instead of
    /// trying to keep showing a number.
    @State private var lastKnownElapsedSeconds: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            recordingDot
            Text(elapsedText)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            pauseResumeButton
            tickerLabel
            Spacer(minLength: 4)
            expandButton
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // `initial: true` seeds the cache from whatever state the pill first appears in (e.g.
        // compacting straight into `.recording`), not just subsequent transitions.
        .onChange(of: viewModel.recordingButtonState, initial: true) { _, newValue in
            if let elapsedSeconds = newValue.elapsedSecondsForDisplay {
                lastKnownElapsedSeconds = elapsedSeconds
            }
        }
    }

    // MARK: Recording dot

    /// Recording: red: Paused (including `.pausedDisabledOtherRecording`): gray (§3.4's mockup).
    private var recordingDot: some View {
        Circle()
            .fill(isRecording ? Color.red : Color.secondary)
            .frame(width: 8, height: 8)
    }

    private var isRecording: Bool {
        if case .recording = viewModel.recordingButtonState { return true }
        return false
    }

    private var elapsedText: String {
        if let elapsedSeconds = viewModel.recordingButtonState.elapsedSecondsForDisplay {
            return TimeFormatting.clock(seconds: elapsedSeconds)
        }
        // `.pausing`/`.resuming` (the only transitions reachable while compact, per
        // `RecordingButtonState.showsStowControls`) have no `elapsedSeconds` of their own -- keep
        // showing the last known value instead of flashing to "00:00" for the await's duration.
        return TimeFormatting.clock(seconds: lastKnownElapsedSeconds)
    }

    // MARK: Pause/resume

    /// `⏸`/`▶` following `recordingButtonState`, same AX contract as the normal header's
    /// `RecordingControlView` (`MeetingWorkspaceView.swift`).
    @ViewBuilder
    private var pauseResumeButton: some View {
        switch viewModel.recordingButtonState {
        case .recording:
            Button {
                Task { await viewModel.pauseRecording() }
            } label: {
                Image(systemName: "pause.fill")
            }
            .controlSize(.small)
            .help("一時停止")
            .accessibilityLabel("一時停止")

        case .paused:
            Button {
                Task { await viewModel.resumeRecording() }
            } label: {
                Image(systemName: "record.circle")
            }
            .controlSize(.small)
            .help("録音再開")
            .accessibilityLabel("録音再開")

        case .pausedDisabledOtherRecording:
            // kikimi.md 10 章: another window is Recording, so resume stays disabled here too.
            Button {
                Task { await viewModel.resumeRecording() }
            } label: {
                Image(systemName: "record.circle")
            }
            .controlSize(.small)
            .disabled(true)
            .help("録音再開")
            .accessibilityLabel("録音再開")

        default:
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Ticker

    /// §3.4: "バナーが1件以上あるときはティッカーの左に⚠を出す（クリックで展開）".
    private var tickerLabel: some View {
        HStack(spacing: 4) {
            if !viewModel.banners.isEmpty {
                Button {
                    viewModel.windowMode = .normal
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help("警告があります。クリックして展開")
                .accessibilityLabel("警告があります。クリックして展開")
            }
            Text(tickerText ?? "書き起こしを待っています…")
                .font(.callout)
                .foregroundStyle(tickerText == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tickerText: String? {
        CompactTicker.text(
            rows: viewModel.transcriptRows,
            micVolatileText: viewModel.micVolatileText,
            systemVolatileText: viewModel.systemVolatileText,
            micConfirmingText: viewModel.micConfirmingText,
            systemConfirmingText: viewModel.systemConfirmingText
        )
    }

    // MARK: Expand

    private var expandButton: some View {
        Button {
            viewModel.windowMode = .normal
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .controlSize(.small)
        .help("元のサイズに戻す")
        .accessibilityLabel("元のサイズに戻す")
    }
}
