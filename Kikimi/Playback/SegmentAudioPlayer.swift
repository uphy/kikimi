import AVFoundation
import Foundation
import OSLog

// MARK: - SegmentAudioPlayer

/// Plays one Transcript-row audio slice at a time from a session's own `mic_NNN.wav`/
/// `system_NNN.wav` files (`docs/design/15-segment-playback.md`). Owns a single `AVAudioPlayer` --
/// starting a new `play(...)` call always stops whatever was previously playing first, matching the
/// design's "同時に再生できるセグメントは1つ" rule (section 6).
@MainActor
final class SegmentAudioPlayer {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SegmentAudioPlayer")

    /// The `TranscriptSegment.id` currently playing, `nil` while idle. `MeetingWorkspaceViewModel`
    /// mirrors this into its own `@Published playingSegmentId` via `onPlayingSegmentChanged` so
    /// SwiftUI observes every transition (start, manual stop, natural end).
    private(set) var playingSegmentId: String?

    /// Fired on every `playingSegmentId` transition. Set once by the owning view model at
    /// construction time; never called re-entrantly (all mutation happens on the main actor).
    var onPlayingSegmentChanged: ((String?) -> Void)?

    private var player: AVAudioPlayer?
    /// Auto-stops playback once the slice's clamped duration elapses -- `AVAudioPlayer` has no
    /// built-in "play only N seconds from here" primitive, so this is a plain timer implemented as a
    /// cancellable sleep. Cancelled by any subsequent `play(...)`/`stop()` call.
    private var stopTask: Task<Void, Never>?

    /// Stops whatever is currently playing, then plays `durationMs` of `fileURL` starting at
    /// `localStartMs` (`docs/design/15-segment-playback.md` section 3's WAV-local offsets).
    ///
    /// Every failure mode here (section 5) is logged and silently absorbed -- a failed playback
    /// attempt must never surface as an error to the user, since it is a purely incidental
    /// convenience feature layered on top of the recording/transcription pipeline that must never be
    /// affected by it (kikimi.md 6 章 "録音は絶対に止めない").
    func play(segmentId: String, fileURL: URL, localStartMs: Int, durationMs: Int) {
        stop()

        let newPlayer: AVAudioPlayer
        do {
            newPlayer = try AVAudioPlayer(contentsOf: fileURL)
        } catch {
            Self.logger.warning(
                "Failed to open audio file for segment \(segmentId, privacy: .public) at \(fileURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }

        let startSeconds = Double(localStartMs) / 1_000
        let remainingSeconds = newPlayer.duration - startSeconds
        guard remainingSeconds > 0 else {
            // Stale WAV header (duration not yet flushed past this point) or a segment whose audio
            // hasn't been written yet -- neither is an error, just "nothing to play right now".
            Self.logger.info(
                "No remaining audio to play for segment \(segmentId, privacy: .public) (duration=\(newPlayer.duration, privacy: .public)s, start=\(startSeconds, privacy: .public)s)"
            )
            return
        }

        let playSeconds = min(Double(durationMs) / 1_000, remainingSeconds)
        newPlayer.currentTime = startSeconds
        guard newPlayer.play() else {
            Self.logger.warning("AVAudioPlayer.play() returned false for segment \(segmentId, privacy: .public)")
            return
        }

        player = newPlayer
        playingSegmentId = segmentId
        onPlayingSegmentChanged?(segmentId)

        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(playSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(segmentId: segmentId)
        }
    }

    /// Stops playback if `segmentId` is still the one playing -- guards against a stale, already-
    /// cancelled `stopTask` firing after a newer `play(...)`/`stop()` call already moved on.
    private func finish(segmentId: String) {
        guard playingSegmentId == segmentId else { return }
        stop()
    }

    /// Stops playback (if any) and fires `onPlayingSegmentChanged` only when `playingSegmentId`
    /// actually changes, so redundant calls (e.g. `stop()` on an already-idle player) are silent.
    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil

        guard playingSegmentId != nil else { return }
        playingSegmentId = nil
        onPlayingSegmentChanged?(nil)
    }
}
