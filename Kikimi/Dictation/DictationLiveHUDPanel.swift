import AppKit
import SwiftUI

// MARK: - DictationElapsedTimeFormatter

/// Pure `m:ss` formatter for the HUD's elapsed-time readout (Handy's own HUD convention, e.g.
/// `0:06`, `1:05`). Kept as a standalone `enum` (no state) so it is trivially unit-testable without
/// any AppKit/SwiftUI dependency, mirroring `MeetingWorkspaceViewModel`'s own elapsed-time display
/// which formats through plain `Int` seconds rather than `DateComponentsFormatter`.
enum DictationElapsedTimeFormatter {
    /// Negative input (a stale tick racing `hide()`, or clock skew) clamps to `0:00` rather than
    /// emitting a negative string.
    static func format(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let remainder = clamped % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}

// MARK: - DictationLiveHUDLayout

/// Shared sizing between the SwiftUI content and the `NSPanel` frame that hosts it -- both need
/// the exact same `CGSize` so the borderless panel never shows a gap around (or clips) the
/// rounded-rect background `DictationLiveHUDView` paints.
private enum DictationLiveHUDLayout {
    static let size = CGSize(width: 420, height: 104)
    static let bottomMargin: CGFloat = 40
    static let accent = Color(red: 0.93, green: 0.20, blue: 0.55)
}

// MARK: - DictationLiveHUDPresenting

/// `DictationController`'s view of the live-preview HUD
/// (`docs/design/32-dictation-hud-refining-visibility.md` §3.1): the controller holds
/// `any DictationLiveHUDPresenting` built by an injected factory, so layer-1 tests can substitute
/// a spy and verify the show/beginProcessing/hide wiring without ever creating an `NSPanel`.
@MainActor
protocol DictationLiveHUDPresenting: AnyObject {
    func show()
    /// Word-drop fix 3b: switches the HUD from its "マイク準備中…" phase (set by `show()`) to the
    /// capturing dot/waveform/elapsed-time display. Called once the mic's first buffer actually
    /// arrives, so the HUD visually distinguishes "hotkey pressed" from "mic is really listening".
    func markCapturing()
    func beginProcessing()
    func updateText(_ text: String)
    func hide()
}

// MARK: - DictationLiveHUDState

/// `@Published` backing for `DictationLiveHUDView`, owned by `DictationLiveHUDPanelController` and
/// updated from `DictationController`'s mic-feed callback (text) and its own per-second ticker
/// (elapsed time). Kept separate from the controller so `updateText(_:)` never has to rebuild the
/// `NSHostingView` (same rationale as `DictationOverlayState`).
@MainActor
private final class DictationLiveHUDState: ObservableObject {
    /// Which bottom row the HUD shows (`docs/design/32-dictation-hud-refining-visibility.md` HR2,
    /// extended by word-drop fix 3b's `.preparing`): a "マイク準備中…" spinner from `show()` until
    /// the mic's first buffer arrives, then the recording dot/waveform/elapsed-time while actually
    /// capturing, or the refining spinner during the key-up tail (batch re-decode through
    /// insertion) when `dictation.refine` keeps it visible.
    enum Phase {
        case preparing
        case capturing
        case processing
    }

    @Published var text: String = ""
    @Published var elapsedSeconds: Int = 0
    @Published var phase: Phase = .preparing
}

// MARK: - DictationRecordingDot

/// The pink pulsing "recording" indicator (left of the bottom row in the Handy reference
/// screenshot). Purely decorative -- no pure logic to test here, unlike the elapsed-time
/// formatter above.
private struct DictationRecordingDot: View {
    @State private var isDim = false

    var body: some View {
        Circle()
            .fill(DictationLiveHUDLayout.accent)
            .frame(width: 10, height: 10)
            .opacity(isDim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isDim = true
                }
            }
    }
}

// MARK: - DictationWaveformView

/// A decorative stand-in for real audio-level metering (`docs/design/25-dictation-mode.md`'s HUD
/// section deliberately scopes this down to "an animation that reads as audio activity", not
/// actual level analysis) -- a row of dots pulsing with a staggered delay per dot.
private struct DictationWaveformView: View {
    private let dotCount = 5
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< dotCount, id: \.self) { index in
                Circle()
                    .fill(DictationLiveHUDLayout.accent.opacity(0.7))
                    .frame(width: 5, height: 5)
                    .scaleEffect(isAnimating ? 1.6 : 0.6)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(index) * 0.12),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = true }
    }
}

// MARK: - DictationLiveHUDView

/// The HUD's content (`docs/design/25-dictation-mode.md`'s "ライブプレビューHUD" section): a white
/// rounded-rect pill with the live transcript on top, and a phase-dependent bottom row -- a
/// "マイク準備中…" spinner before the mic's first buffer arrives (word-drop fix 3b), the dot /
/// waveform / elapsed-time while actually capturing, or a spinner + "整形中…" during the key-up
/// tail (`docs/design/32-dictation-hud-refining-visibility.md` HR2). No close button either way:
/// the HUD stays display-only and disappears on its own when the tail ends.
private struct DictationLiveHUDView: View {
    @ObservedObject fileprivate var state: DictationLiveHUDState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.text.isEmpty ? headline : state.text)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                // `.head` keeps the *newest* words on screen as the utterance grows past two
                // lines, rather than freezing on whatever was said first.
                .truncationMode(.head)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)

            HStack {
                switch state.phase {
                case .preparing:
                    ProgressView()
                        .controlSize(.small)
                    Text("マイク準備中…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                case .capturing:
                    DictationRecordingDot()
                    Spacer()
                    DictationWaveformView()
                    Spacer()
                    Text(DictationElapsedTimeFormatter.format(seconds: state.elapsedSeconds))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                case .processing:
                    ProgressView()
                        .controlSize(.small)
                    Text("整形中…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(width: DictationLiveHUDLayout.size.width, height: DictationLiveHUDLayout.size.height)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    /// Placeholder text shown while `state.text` is still empty -- distinct wording for `.preparing`
    /// (word-drop fix 3b) so the HUD doesn't claim to be "聞き取り中" before the mic has actually
    /// delivered anything yet.
    private var headline: String {
        state.phase == .preparing ? "マイク準備中…" : "聞き取り中…"
    }
}

// MARK: - DictationLiveHUDPanelController

/// The live-preview HUD (`docs/design/25-dictation-mode.md`'s "ライブプレビューHUD" section, as
/// revised by `docs/design/32-dictation-hud-refining-visibility.md`): shown the instant a hotkey
/// key-down starts an utterance and fed the transcriber's cumulative text on every chunk boundary.
/// At key-up it either hides immediately (`dictation.refine` off -- design 25 H1's original
/// behavior) or switches to the "整形中…" processing phase and stays up until the
/// transcribe/refine/insert tail ends (design 32 HR1). Built on the same shared `FloatingPanel`
/// base as every other Kikimi window, using the `.borderless` style (`FloatingPanel.Style`) since
/// a HUD has no title bar, close box, or resize handles.
///
/// A single long-lived instance owned by `DictationController`, lazily created on first use and
/// reused across every subsequent utterance -- mirrors `DictationOverlayPanelController`'s
/// singleton-per-window-kind lifecycle.
@MainActor
final class DictationLiveHUDPanelController: NSWindowController, DictationLiveHUDPresenting {
    private let state = DictationLiveHUDState()
    private var tickerTask: Task<Void, Never>?
    private var startDate: Date?

    init() {
        let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: DictationLiveHUDLayout.size), style: .borderless)
        panel.isMovableByWindowBackground = false
        panel.isRestorable = false
        // Display-only: never intercept a click meant for whatever app is underneath it (the
        // HUD has no buttons, unlike `DictationOverlayPanel`).
        panel.ignoresMouseEvents = true

        super.init(window: panel)

        panel.contentView = FirstMouseHostingView(rootView: DictationLiveHUDView(state: state))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Resets the transcript/timer, re-anchors to the bottom-center of the main screen (position
    /// is recomputed on every `show()` rather than cached, in case the display configuration
    /// changed since the last utterance), and starts the per-second elapsed-time ticker. Never
    /// activates the app or takes key focus (`orderFront`, not `makeKeyAndOrderFront`) -- the HUD
    /// must not interrupt whatever app the user is dictating into.
    func show() {
        state.text = ""
        state.elapsedSeconds = 0
        // Word-drop fix 3b: starts in `.preparing` -- `show()` fires the instant the hotkey is
        // pressed, before the mic has necessarily delivered anything yet. `markCapturing()`
        // advances this to `.capturing` once it actually has.
        state.phase = .preparing
        positionAtBottomCenter()
        startTicker()
        if !HiddenTestMode.isActive {
            window?.orderFront(nil)
        }
    }

    /// Word-drop fix 3b: the mic's first actually-delivered buffer. A no-op once already past
    /// `.preparing` (every buffer after the first calls this too) so it never resets `.processing`
    /// back to `.capturing` after a very-fast key-up.
    func markCapturing() {
        guard state.phase == .preparing else { return }
        state.phase = .capturing
    }

    /// Key-up with `dictation.refine` enabled (`docs/design/32-dictation-hud-refining-visibility.md`
    /// HR1/HR2): stop the elapsed-time ticker and swap the bottom row to the refining spinner while
    /// the transcribe/refine/insert tail runs. The window itself stays visible -- `hide()` follows
    /// at the tail's end.
    func beginProcessing() {
        stopTicker()
        state.phase = .processing
    }

    /// Called by `DictationController` at key-up when `dictation.refine` is off (design 25 H1's
    /// original immediate-hide behavior) and unconditionally at the end of every key-up tail path
    /// (design 32 HR4). Idempotent: `orderOut` on an already-hidden window is a no-op.
    func hide() {
        stopTicker()
        window?.orderOut(nil)
    }

    /// Forwards `DictationTranscriber.feed(samples:)`'s cumulative text straight to the HUD.
    func updateText(_ text: String) {
        state.text = text
    }

    /// One-second `Task.sleep` loop, mirroring `MeetingWorkspaceViewModel.startElapsedTimer()`'s
    /// own ticker pattern rather than `Timer` (`docs/design/25-dictation-mode.md`'s HUD section
    /// has no dedicated rationale for this beyond following the codebase's existing convention for
    /// per-second UI ticking).
    private func startTicker() {
        tickerTask?.cancel()
        let start = Date()
        startDate = start
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.state.elapsedSeconds = max(0, Int(Date().timeIntervalSince(start)))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
        startDate = nil
    }

    private func positionAtBottomCenter() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = DictationLiveHUDLayout.size
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + DictationLiveHUDLayout.bottomMargin
        )
        window.setFrame(CGRect(origin: origin, size: size), display: false)
    }
}
