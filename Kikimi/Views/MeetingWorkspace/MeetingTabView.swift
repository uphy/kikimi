import SwiftUI

// MARK: - MeetingTabView

/// The Session Window's "会議" tab (`docs/design/17-session-window-redesign.md` §3.2/§5.3;
/// supersedes `docs/design/06-ui-panels.md` section 6.3/6.4's separate Transcript/Summary tabs, R2):
/// a 3-state pane switcher (書き起こしのみ / 両方 / サマリのみ) over the same `TranscriptTabView`/
/// `SummaryTabView` those tabs used to host directly, unchanged.
///
/// Generic over its two content builders so this view stays exactly as decoupled from
/// `MeetingWorkspaceViewModel` as its siblings (`PrepContentView`/`WatchersTabView`/
/// `TranscriptTabView`): `MeetingWorkspaceView` supplies `transcriptContent`/`summaryContent`
/// closures that construct the real `TranscriptTabView`/`SummaryTabView` with the exact same wiring
/// those tabs used before this redesign (moved here verbatim, per §5.3's "配線パラメータは... 移設").
struct MeetingTabView<TranscriptContent: View, SummaryContent: View>: View {
    @Binding var paneMode: MeetingPaneMode

    /// `MeetingWorkspaceViewModel.summaryHasUnseenUpdate` verbatim (§4.4): drives the small accent-
    /// color dot on the "サマリのみ表示" button whenever a summary update arrived while the pane
    /// wasn't visible.
    var summaryHasUnseenUpdate: Bool = false

    @ViewBuilder var transcriptContent: () -> TranscriptContent
    @ViewBuilder var summaryContent: () -> SummaryContent

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Spacer()
            paneButton(mode: .transcript, systemImage: "list.bullet.rectangle", label: "書き起こしのみ表示")
            paneButton(mode: .both, systemImage: "rectangle.split.2x1", label: "両方表示")
            paneButton(mode: .summary, systemImage: "doc.text", label: "サマリのみ表示", showsUnseenDot: summaryHasUnseenUpdate)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// One toolbar button. A custom button (not `Picker(.segmented)`) so the "サマリのみ表示" icon can
    /// carry the small unseen-update dot in its top-right corner (§5.3: "セグメント標準コントロールで
    /// ドットを重ねられない場合はカスタムボタン群で実装してよい").
    private func paneButton(mode: MeetingPaneMode, systemImage: String, label: String, showsUnseenDot: Bool = false) -> some View {
        let isSelected = paneMode == mode
        return Button {
            paneMode = mode
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(6)
                    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if showsUnseenDot {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        // AX contract for `kikimi-verify`/System Events scripting (`docs/design/17-session-window
        // -redesign.md` §5.3/§6): `.help` backs AppleScript's `get help of button`,
        // `.accessibilityLabel` backs AX name lookups -- kept in exact sync with the design's table.
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var content: some View {
        switch paneMode {
        case .transcript:
            transcriptContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .summary:
            summaryContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .both:
            // §5.3: each pane never narrower than 240pt, resizable by dragging the divider.
            //
            // Known cosmetic gap vs. the design's "初期比率 6:4": neither `idealWidth` (a plain
            // `.frame(idealWidth:)` hint) nor a `GeometryReader`-computed explicit width changed the
            // initial split away from ~50:50 in manual `kikimi-verify` testing -- `HSplitView`
            // (`NSSplitView` under the hood) appears to ignore both once both children share the same
            // `minWidth`/`maxWidth: .infinity`. Getting a true 6:4 starting position would need an
            // `NSSplitViewController`-level API SwiftUI doesn't expose here, which is out of scope for
            // this pass; every other behavior (min-width, free resizing, pane switching) is correct.
            HSplitView {
                transcriptContent()
                    .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                summaryContent()
                    .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
