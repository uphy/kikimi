import SwiftUI

// MARK: - AudioInputPopoverButton

/// Header button that opens the input-selection popover. See
/// `docs/design/10-audio-input-selection.md` section 7.1.
///
/// Placed immediately before `recordingControl` in `MeetingWorkspaceView`'s header `HStack`. The
/// caller (`MeetingWorkspaceView`) is responsible for hiding this button entirely once
/// `recordingButtonState == .ended` (section 7.1: "Ended は非表示"); this view itself only
/// decides whether the popover's *contents* are editable (`AudioInputPopoverContent.isReadOnly`).
struct AudioInputPopoverButton: View {
    @ObservedObject var viewModel: MeetingWorkspaceViewModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.audioInputSelection.mic.enabled ? "mic" : "mic.slash")
                    .foregroundStyle(viewModel.audioInputSelection.mic.enabled ? Color.primary : Color.secondary)
                Image(systemName: viewModel.audioInputSelection.system.enabled ? "speaker.wave.2" : "speaker.slash")
                    .foregroundStyle(viewModel.audioInputSelection.system.enabled ? Color.primary : Color.secondary)
            }
            // Makes the whole label -- including the gap between the two icons -- part of the
            // hit area, rather than only the icon glyphs themselves.
            .contentShape(Rectangle())
        }
        // No explicit `.buttonStyle` here, matching `recordingControl`'s buttons (see
        // `RecordingControlView` in `MeetingWorkspaceView.swift`): both pick up the platform's
        // default bezeled push-button appearance so the two header controls look like a pair.
        // AX contract for `kikimi-verify`/System Events scripting: `.help` backs AppleScript's
        // `get help of button`, `.accessibilityLabel` backs AX name lookups. Keep both in sync.
        .help("録音入力を設定")
        .accessibilityLabel("録音入力を設定")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AudioInputPopoverContent(viewModel: viewModel)
        }
    }
}

// MARK: - AudioInputPopoverContent

/// The popover body itself (`docs/design/10-audio-input-selection.md` section 7.2): a Toggle +
/// Picker per source, plus a warning row when both sources are disabled.
struct AudioInputPopoverContent: View {
    @ObservedObject var viewModel: MeetingWorkspaceViewModel

    /// `docs/design/10-audio-input-selection.md` section 7.1: Recording/starting/stopping show the
    /// popover as a read-only view of the configuration actually in use. `RecordingButtonState
    /// .blocksWindowClose` already answers exactly this question (true for
    /// `.recording`/`.starting`/`.stopping`), so it is reused here rather than duplicating the
    /// switch.
    private var isReadOnly: Bool { viewModel.recordingButtonState.blocksWindowClose }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("録音入力")
                .font(.headline)

            micSection
            systemAudioSection

            if !viewModel.audioInputSelection.hasEnabledSource {
                warningRow
            }
        }
        // macOS standard popover inset (~12pt) rather than the wider 16pt used before, so the
        // content sits snugly against the popover edge like other system popovers.
        .padding(12)
        // Hug the content's intrinsic width instead of a fixed 320pt frame (which centered the
        // narrower content, leaving wide side margins); min/max only guard against extreme
        // shrinking/stretching from unusually short/long device or app names.
        .frame(minWidth: 200, maxWidth: 360, alignment: .leading)
        // section 2 / 7.2: re-enumerate every time the popover opens.
        .onAppear { viewModel.refreshAudioInputs() }
    }

    // MARK: Microphone

    private var micSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("マイク", isOn: $viewModel.audioInputSelection.mic.enabled)
                .disabled(isReadOnly)

            Picker("", selection: $viewModel.audioInputSelection.mic.deviceUid) {
                // Fixed first row (section 7.2): `deviceUid == nil` == "follow the system default
                // input device".
                Text("システムデフォルト").tag(String?.none)
                ForEach(viewModel.availableInputDevices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(isReadOnly || !viewModel.audioInputSelection.mic.enabled)
        }
    }

    // MARK: System audio

    private var systemAudioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("システム音声", isOn: $viewModel.audioInputSelection.system.enabled)
                .disabled(isReadOnly)

            Picker("", selection: $viewModel.audioInputSelection.system.bundleId) {
                // Fixed first row (section 7.2): `bundleId == nil` == "All System Audio".
                Text("すべてのシステム音声").tag(String?.none)

                // section 6.1/7.2: keep a selected bundle id visible even when the fresh
                // enumeration no longer contains it (the app isn't currently producing audio
                // output), so the selection itself is preserved rather than silently reset.
                if let staleBundleId = staleSystemAudioSelection {
                    Text("\(staleBundleId)（停止中）").tag(String?.some(staleBundleId))
                }

                ForEach(viewModel.availableSystemAudioApps) { app in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.displayName)
                        Text(app.bundleId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(String?.some(app.bundleId))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(isReadOnly || !viewModel.audioInputSelection.system.enabled)
        }
    }

    /// The currently-selected `bundleId` when it is not present in the freshly-enumerated
    /// `availableSystemAudioApps` (e.g. the app hasn't started producing audio output yet). `nil`
    /// selection ("All System Audio") never counts as stale.
    private var staleSystemAudioSelection: String? {
        guard let bundleId = viewModel.audioInputSelection.system.bundleId else { return nil }
        guard !viewModel.availableSystemAudioApps.contains(where: { $0.bundleId == bundleId }) else {
            return nil
        }
        return bundleId
    }

    // MARK: Warning row

    private var warningRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("少なくとも1つの入力を有効にしてください")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
