import SwiftUI

// MARK: - CopyFeedbackFlash

/// Pure decision behind the copy toolbar's checkmark-flash timing (`docs/design/37-transcript-markdown
/// -copy.md` §3.3/TC11), factored out of `MeetingTabView.copyMenu`'s `.task(id: copyFeedbackToken)`
/// closure so this logic is directly unit-testable without instantiating a SwiftUI view -- the same
/// pattern `SessionListContextMenuAvailability` (`Kikimi/Views/SessionListView.swift`) uses for its
/// context menu's enable/disable rules.
enum CopyFeedbackFlash {
    /// Whether a `.task(id: copyFeedbackToken)` firing should flash the checkmark, given whether the
    /// view has already observed its *first* firing once before. The very first firing carries
    /// whatever `copyFeedbackToken` value the caller started at (not necessarily `0`) and must never be
    /// treated as "a copy just happened"; every firing after that was triggered by an actual
    /// `copyFeedbackToken` bump from a successful copy and must flash.
    static func shouldFlash(hasObservedInitialToken: Bool) -> Bool {
        hasObservedInitialToken
    }
}

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

    /// Invoked with the requested copy scope (design 37 §3.3/TC6). Callers own the actual clipboard
    /// write and success/failure handling (`MeetingWorkspaceViewModel.copyMarkdown(scope:)`); this
    /// view only decides *which* scope was requested.
    var onCopy: (TranscriptMarkdownRenderer.Scope) -> Void

    /// `MeetingWorkspaceViewModel.copyFeedbackToken` verbatim (design 37 §3.3/TC11): bumped by the
    /// caller after a successful copy so this view can flash the `checkmark` icon for 1.5s. The
    /// initial value is never treated as a "just copied" signal (see `copyFeedbackTask(id:)` below).
    var copyFeedbackToken: Int

    @ViewBuilder var transcriptContent: () -> TranscriptContent
    @ViewBuilder var summaryContent: () -> SummaryContent

    /// Whether the copy button icon is currently showing `checkmark` instead of `doc.on.doc`
    /// (design 37 TC11).
    @State private var showsCopyFeedback = false

    /// Tracks whether `copyFeedbackToken` has been observed once already, so the `.task(id:)` that
    /// fires on this view's first appearance (with whatever token value the caller started at)
    /// doesn't spuriously flash the checkmark before any copy has happened.
    @State private var hasObservedInitialCopyFeedbackToken = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            copyMenu
            Spacer()
            paneButton(mode: .transcript, systemImage: "list.bullet.rectangle", label: "書き起こしのみ表示")
            paneButton(mode: .both, systemImage: "rectangle.split.2x1", label: "両方表示")
            paneButton(mode: .summary, systemImage: "doc.text", label: "サマリのみ表示", showsUnseenDot: summaryHasUnseenUpdate)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Copy toolbar entry point (design 37 §3.3, `MeetingTabView.swift:34`'s `toolbar`, left of
    /// `Spacer()`). Clicking the icon itself copies the full document (`primaryAction`); the
    /// dropdown offers the 3 scopes from TC6. ⌘⇧C mirrors the icon click (TC8) -- ⌘C is deliberately
    /// left alone so text-selection copy in the transcript rows keeps working.
    private var copyMenu: some View {
        Menu {
            Button("全体をコピー") { onCopy(.full) }
            Button("書き起こしをコピー") { onCopy(.transcript) }
            Button("サマリをコピー") { onCopy(.summary) }
        } label: {
            Image(systemName: showsCopyFeedback ? "checkmark" : "doc.on.doc")
                .font(.body)
                .foregroundStyle(Color.secondary)
                .padding(6)
        } primaryAction: {
            onCopy(.full)
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        // AX contract, same as `paneButton` below (design 17 §5.3/§6): `.help` backs AppleScript's
        // `get help of button`, `.accessibilityLabel` backs AX name lookups used by `kikimi-verify`.
        .help("Markdown をコピー")
        .accessibilityLabel("Markdown をコピー")
        .task(id: copyFeedbackToken) {
            let shouldFlash = CopyFeedbackFlash.shouldFlash(hasObservedInitialToken: hasObservedInitialCopyFeedbackToken)
            hasObservedInitialCopyFeedbackToken = true
            guard shouldFlash else { return }
            showsCopyFeedback = true
            try? await Task.sleep(for: .seconds(1.5))
            // A rapid second copy cancels this task and starts a fresh one (new `copyFeedbackToken`),
            // which immediately re-sets `showsCopyFeedback = true`. `Task.sleep` throws on
            // cancellation but that alone doesn't stop this task's remaining statements, so without
            // this check the stale task would still run `showsCopyFeedback = false` right after the
            // new task turned it back on, cutting the second copy's checkmark short.
            guard !Task.isCancelled else { return }
            showsCopyFeedback = false
        }
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
