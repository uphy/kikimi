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
///
/// Two sizes, one per role (`docs/design/49-dictation-hud-slim.md` HS2): while the user is
/// speaking the HUD carries no text and shrinks to a pill that stays out of the way, and it
/// expands only for the key-up tail, where there is a confirmed transcript worth reading.
private enum DictationLiveHUDLayout {
    static let compactSize = CGSize(width: 240, height: 48)
    static let expandedSize = CGSize(width: 420, height: 104)
    static let cornerRadius: CGFloat = 24
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
    /// capturing dot/level-bars/elapsed-time display. Called once the mic's first buffer actually
    /// arrives, so the HUD visually distinguishes "hotkey pressed" from "mic is really listening".
    func markCapturing()
    /// One mic buffer's RMS amplitude (`docs/design/49-dictation-hud-slim.md` HS4), already
    /// computed on the tap's callback thread. Normalization and smoothing happen here, on the
    /// main actor, so the caller only ever hands over a single `Float`.
    func updateLevel(_ rms: Float)
    func beginProcessing()
    /// The confirmed raw transcript, shown during the key-up tail only (HS1). Nothing is displayed
    /// while the user is still speaking -- that text would be the first-pass decode, which the
    /// batch re-decode and the refine both go on to rewrite.
    func updateText(_ text: String)
    func hide()
}

// MARK: - DictationLiveHUDState

/// `@Published` backing for `DictationLiveHUDView`, owned by `DictationLiveHUDPanelController` and
/// updated from `DictationController`'s mic-feed callback (level), the key-up tail (text) and its
/// own per-second ticker (elapsed time). Kept separate from the controller so `updateLevel(_:)`
/// never has to rebuild the `NSHostingView` (same rationale as `DictationOverlayState`).
@MainActor
private final class DictationLiveHUDState: ObservableObject {
    /// What the HUD shows (`docs/design/32-dictation-hud-refining-visibility.md` HR2, extended by
    /// word-drop fix 3b's `.preparing` and narrowed by `docs/design/49-dictation-hud-slim.md`
    /// HS1/HS2): a "マイク準備中…" spinner from `show()` until the mic's first buffer arrives, then
    /// the recording dot/level bars/elapsed time while actually capturing -- both in the compact
    /// pill, neither showing any transcript -- or, during the key-up tail (batch re-decode through
    /// insertion) when `dictation.refine` keeps it visible, the expanded panel with the confirmed
    /// raw text above a refining spinner.
    enum Phase {
        case preparing
        case capturing
        case processing

        var size: CGSize {
            self == .processing ? DictationLiveHUDLayout.expandedSize : DictationLiveHUDLayout.compactSize
        }
    }

    @Published var text: String = ""
    @Published var elapsedSeconds: Int = 0
    @Published var phase: Phase = .preparing
    /// Normalized, smoothed 0...1 mic level driving the capturing-phase bars.
    @Published var level: Float = 0
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

// MARK: - DictationLevelBarsView

/// Five bars driven by the real mic level (`docs/design/49-dictation-hud-slim.md` HS4), replacing
/// the decorative waveform design 25 originally specified. With the live transcript gone, this is
/// the only thing on screen that says the mic is actually hearing something -- so it must not move
/// when it is not. Silence leaves every bar at its minimum height.
///
/// No randomness: the same sound always draws the same shape, which is what makes a level meter
/// believable. The per-bar weights only shape it, tallest in the middle.
private struct DictationLevelBarsView: View {
    private static let weights: [Float] = [0.55, 0.8, 1.0, 0.8, 0.55]
    private static let minHeight: CGFloat = 3
    private static let maxHeight: CGFloat = 18

    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(DictationLiveHUDLayout.accent.opacity(0.85))
                    .frame(width: 3, height: height(weight: weight))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func height(weight: Float) -> CGFloat {
        let scaled = CGFloat(max(0, min(1, level)) * weight)
        return Self.minHeight + (Self.maxHeight - Self.minHeight) * scaled
    }
}

// MARK: - DictationLiveHUDView

/// The HUD's content (`docs/design/25-dictation-mode.md`'s "ライブプレビューHUD" section, as
/// revised by `docs/design/49-dictation-hud-slim.md`): a white rounded-rect panel that takes one
/// of two shapes.
///
/// While the user speaks it is a compact pill with no text at all -- a "マイク準備中…" spinner
/// before the mic's first buffer arrives (word-drop fix 3b), then the recording dot, the live
/// level bars and the elapsed time. During the key-up tail it expands to show the confirmed raw
/// transcript above a "整形中…" spinner (`docs/design/32-dictation-hud-refining-visibility.md`
/// HR2). No close button in either shape: the HUD stays display-only and disappears on its own
/// when the tail ends.
private struct DictationLiveHUDView: View {
    @ObservedObject fileprivate var state: DictationLiveHUDState

    var body: some View {
        Group {
            switch state.phase {
            case .preparing:
                compactRow {
                    ProgressView()
                        .controlSize(.small)
                    Text("マイク準備中…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            case .capturing:
                compactRow {
                    DictationRecordingDot()
                    Spacer()
                    DictationLevelBarsView(level: state.level)
                    Spacer()
                    Text(DictationElapsedTimeFormatter.format(seconds: state.elapsedSeconds))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            case .processing:
                processingBody
            }
        }
        .frame(width: state.phase.size.width, height: state.phase.size.height)
        .background(
            RoundedRectangle(cornerRadius: DictationLiveHUDLayout.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    private func compactRow(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var processingBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.text.isEmpty ? "整形中…" : state.text)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                // `.head` keeps the *end* of a long utterance on screen -- the part the user is
                // most likely to be checking before it lands in the target app.
                .truncationMode(.head)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)

            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("整形中…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}

// MARK: - DictationLiveHUDPanelController

/// The live HUD (`docs/design/25-dictation-mode.md`'s "ライブプレビューHUD" section, as revised by
/// `docs/design/32-dictation-hud-refining-visibility.md` and `docs/design/49-dictation-hud-slim.md`):
/// shown the instant a hotkey key-down starts an utterance, and fed the mic's level on every
/// buffer while it stays compact. At key-up it either hides immediately (`dictation.refine` off --
/// design 25 H1's original behavior) or expands into the "整形中…" processing phase, showing the
/// confirmed raw text until the transcribe/refine/insert tail ends (design 32 HR1). Built on the
/// same shared `FloatingPanel` base as every other Kikimi window, using the `.borderless` style
/// (`FloatingPanel.Style`) since a HUD has no title bar, close box, or resize handles.
///
/// A single long-lived instance owned by `DictationController`, lazily created on first use and
/// reused across every subsequent utterance -- mirrors `DictationOverlayPanelController`'s
/// singleton-per-window-kind lifecycle.
@MainActor
final class DictationLiveHUDPanelController: NSWindowController, DictationLiveHUDPresenting {
    private let state = DictationLiveHUDState()
    private var tickerTask: Task<Void, Never>?
    private var startDate: Date?
    private var levelSmoother = DictationAudioLevelMeter.Smoother()

    init() {
        let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: DictationLiveHUDLayout.compactSize), style: .borderless)
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
        state.level = 0
        levelSmoother.reset()
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

    /// Normalizes and smooths one buffer's RMS into the 0...1 the bars draw from
    /// (`docs/design/49-dictation-hud-slim.md` HS4). Ignored outside the capturing phase: buffers
    /// can still be in flight when key-up flips the HUD to `.processing`, and a stray one must not
    /// disturb a panel that is no longer showing a meter.
    func updateLevel(_ rms: Float) {
        guard state.phase == .capturing || state.phase == .preparing else { return }
        state.level = levelSmoother.update(DictationAudioLevelMeter.normalize(rms: rms))
    }

    /// Key-up with `dictation.refine` enabled (`docs/design/32-dictation-hud-refining-visibility.md`
    /// HR1/HR2): stop the elapsed-time ticker and swap to the refining spinner while the
    /// transcribe/refine/insert tail runs. The window itself stays visible -- `hide()` follows at
    /// the tail's end -- but it grows to the expanded size so the confirmed raw text has somewhere
    /// to appear (`docs/design/49-dictation-hud-slim.md` HS2). Resized without animation: this
    /// fires while the user is already waiting, and a transition would only lengthen that wait.
    func beginProcessing() {
        stopTicker()
        state.phase = .processing
        state.level = 0
        positionAtBottomCenter()
    }

    /// Called by `DictationController` at key-up when `dictation.refine` is off (design 25 H1's
    /// original immediate-hide behavior) and unconditionally at the end of every key-up tail path
    /// (design 32 HR4). Idempotent: `orderOut` on an already-hidden window is a no-op.
    func hide() {
        stopTicker()
        window?.orderOut(nil)
    }

    /// The confirmed raw text from the key-up tail's decoder selection (design 32 HR2). Nothing
    /// calls this during capture any more (`docs/design/49-dictation-hud-slim.md` HS1).
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

    /// Re-frames the panel for whatever phase it is in and re-anchors it to the bottom center.
    /// Called on both `show()` and `beginProcessing()`, since the width changes between the two
    /// and the x origin has to be recomputed to keep the panel centered.
    private func positionAtBottomCenter() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = state.phase.size
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + DictationLiveHUDLayout.bottomMargin
        )
        window.setFrame(CGRect(origin: origin, size: size), display: false)
    }
}
