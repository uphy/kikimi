import SwiftUI

// MARK: - StowControlButtonsView

/// The header's "[◫]" compact-display button (`docs/design/18-recording-window-stow-and-compact.md`
/// §3.1), placed just before `recordingControl` by `MeetingWorkspaceView`'s `header` whenever
/// `recordingButtonState.showsStowControls` is true. Split into its own file (matching
/// `AudioInputPopover.swift`'s `AudioInputPopoverButton`) purely to keep `MeetingWorkspaceView.swift`
/// under the project's `file_length` lint limit.
///
/// There is deliberately **no** dedicated "しまう" button here (§3.1/§3.2/R1): "しまう" is triggered
/// solely by closing the window (close button / ⌘W -> `MeetingWorkspaceWindowController
/// .windowShouldClose` -> `stow()`), not by a header control.
///
/// Opening `AudioInputPopoverButton`'s popover, if any, closes on its own once compact mode swaps
/// this whole header out of the view hierarchy (§3.4's "コンパクト化時に `AudioInputPopover` が開いて
/// いたら dismiss する") -- no explicit dismiss call is needed here.
struct StowControlButtonsView: View {
    @ObservedObject var viewModel: MeetingWorkspaceViewModel

    var body: some View {
        Button {
            viewModel.windowMode = .compact
        } label: {
            Image(systemName: "rectangle.compress.vertical")
        }
        // AX contract for `kikimi-verify`/System Events scripting: `.help` backs AppleScript's
        // `get help of button`, `.accessibilityLabel` backs AX name lookups.
        .help("コンパクト表示")
        .accessibilityLabel("コンパクト表示")
    }
}
