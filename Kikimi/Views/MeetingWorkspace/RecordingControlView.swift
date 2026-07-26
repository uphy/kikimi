import SwiftUI

// MARK: - Recording control

/// Split out of `MeetingWorkspaceView.swift` (which still owns `header`'s `recordingControl` computed
/// property below) for the same `file_length`-lint reason `RenameSpeakerPopoverView.swift`/
/// `AudioInputPopover.swift` already live in their own files rather than inside whoever presents them.
private struct RecordingControlView: View {
    @ObservedObject var viewModel: MeetingWorkspaceViewModel

    var body: some View {
        switch viewModel.recordingButtonState {
        case .startRecording:
            Button {
                Task { await viewModel.startRecording() }
            } label: {
                Label("録音開始", systemImage: "record.circle")
            }
            // `docs/design/10-audio-input-selection.md` section 6.1: the record button stays
            // disabled whenever no audio input source is enabled, without adding a new
            // `RecordingButtonState` case -- the (not-yet-built) input popover's warning row
            // explains why.
            .disabled(!viewModel.audioInputSelection.hasEnabledSource)
            // AX contract for `kikimi-verify`/System Events scripting: `.help` backs AppleScript's
            // `get help of button`, `.accessibilityLabel` backs AX name lookups. Matches the
            // visible `Label` text so scripts can click by name instead of positional index.
            .help("録音開始")
            .accessibilityLabel("録音開始")

        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("開始中…")
            }
            .foregroundStyle(.secondary)

        case .recording(let elapsedSeconds):
            // kikimi.md 10 章 header table: Recording shows both "一時停止" (stop-only) and "会議終了"
            // (the sole confirmation operation) as separate buttons.
            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.pauseRecording() }
                } label: {
                    Label("一時停止", systemImage: "pause.fill")
                }
                // AX contract for `kikimi-verify`/System Events scripting: see the `.help`/
                // `.accessibilityLabel` note on the "録音開始" button above.
                .help("一時停止")
                .accessibilityLabel("一時停止")
                Button {
                    Task { await viewModel.endMeeting() }
                } label: {
                    Label("会議終了", systemImage: "stop.fill")
                }
                .help("会議終了")
                .accessibilityLabel("会議終了")
                Text(TimeFormatting.clock(seconds: elapsedSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

        case .pausing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("一時停止中…")
            }
            .foregroundStyle(.secondary)

        case .paused(let elapsedSeconds):
            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.resumeRecording() }
                } label: {
                    Label("録音再開", systemImage: "record.circle")
                }
                // AX contract for `kikimi-verify`/System Events scripting: see the `.help`/
                // `.accessibilityLabel` note on the "録音開始" button above.
                .help("録音再開")
                .accessibilityLabel("録音再開")
                Button {
                    Task { await viewModel.endMeeting() }
                } label: {
                    Label("会議終了", systemImage: "stop.fill")
                }
                .help("会議終了")
                .accessibilityLabel("会議終了")
                Text(TimeFormatting.clock(seconds: elapsedSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

        case .pausedDisabledOtherRecording(let elapsedSeconds, _):
            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.resumeRecording() }
                } label: {
                    Label("録音再開", systemImage: "record.circle")
                }
                // kikimi.md 10 章: "他ウィンドウが Recording 中は、このウィンドウの `録音開始`/`録音再開` が
                // disabled". "会議終了" stays enabled: ending a Paused session never needs the
                // recording-exclusivity claim.
                .disabled(true)
                .help("録音再開")
                .accessibilityLabel("録音再開")
                Button {
                    Task { await viewModel.endMeeting() }
                } label: {
                    Label("会議終了", systemImage: "stop.fill")
                }
                .help("会議終了")
                .accessibilityLabel("会議終了")
                Text(TimeFormatting.clock(seconds: elapsedSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

        case .resuming:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("再開中…")
            }
            .foregroundStyle(.secondary)

        case .ending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("終了処理中…")
            }
            .foregroundStyle(.secondary)

        case .disabledOtherRecording:
            Text("他の会議を録音中です")
                .foregroundStyle(.secondary)

        case .ended:
            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.reopenRecording() }
                } label: {
                    Label("再開", systemImage: "arrow.uturn.backward")
                }
                // AX contract for `kikimi-verify`/System Events scripting: see the `.help`/
                // `.accessibilityLabel` note on the "録音開始" button above.
                .help("再開")
                .accessibilityLabel("再開")
                Text(TimeFormatting.clock(seconds: viewModel.meta.durationMs / 1000))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension MeetingWorkspaceView {
    var recordingControl: some View {
        RecordingControlView(viewModel: viewModel)
    }
}
