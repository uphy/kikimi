import Foundation
import Testing

@testable import Kikimi

// MARK: - RecordingButtonState

@Suite("RecordingButtonState")
struct RecordingButtonStateTests {
    @Test("blocksWindowClose is true for every in-flight/active-recording-or-paused state")
    func blocksWindowCloseTrueCases() {
        #expect(RecordingButtonState.starting.blocksWindowClose)
        #expect(RecordingButtonState.recording(elapsedSeconds: 42).blocksWindowClose)
        #expect(RecordingButtonState.pausing.blocksWindowClose)
        #expect(RecordingButtonState.paused(elapsedSeconds: 42).blocksWindowClose)
        #expect(RecordingButtonState.pausedDisabledOtherRecording(elapsedSeconds: 42, otherSessionId: "session-1").blocksWindowClose)
        #expect(RecordingButtonState.resuming.blocksWindowClose)
        #expect(RecordingButtonState.ending.blocksWindowClose)
    }

    @Test("blocksWindowClose is false for startRecording, disabledOtherRecording, and ended")
    func blocksWindowCloseFalseCases() {
        #expect(!RecordingButtonState.startRecording.blocksWindowClose)
        #expect(!RecordingButtonState.disabledOtherRecording(otherSessionId: "session-1").blocksWindowClose)
        #expect(!RecordingButtonState.ended.blocksWindowClose)
    }

    @Test("all cases are covered exhaustively by blocksWindowClose (no silent default)")
    func allCasesCovered() {
        let allCases: [RecordingButtonState] = [
            .startRecording,
            .starting,
            .recording(elapsedSeconds: 0),
            .pausing,
            .paused(elapsedSeconds: 0),
            .pausedDisabledOtherRecording(elapsedSeconds: 0, otherSessionId: "session-1"),
            .resuming,
            .ending,
            .disabledOtherRecording(otherSessionId: "session-1"),
            .ended
        ]
        let blocking = Set(allCases.filter(\.blocksWindowClose).map(String.init(describing:)))
        let nonBlocking = Set(allCases.filter { !$0.blocksWindowClose }.map(String.init(describing:)))

        #expect(blocking.count == 7)
        #expect(nonBlocking.count == 3)
        #expect(blocking.isDisjoint(with: nonBlocking))
    }

    @Test("recording carries its elapsedSeconds through Equatable comparison")
    func recordingElapsedSecondsEquality() {
        #expect(RecordingButtonState.recording(elapsedSeconds: 5) == .recording(elapsedSeconds: 5))
        #expect(RecordingButtonState.recording(elapsedSeconds: 5) != .recording(elapsedSeconds: 6))
    }

    @Test("disabledOtherRecording carries its otherSessionId through Equatable comparison")
    func disabledOtherRecordingSessionIdEquality() {
        #expect(RecordingButtonState.disabledOtherRecording(otherSessionId: "a") == .disabledOtherRecording(otherSessionId: "a"))
        #expect(RecordingButtonState.disabledOtherRecording(otherSessionId: "a") != .disabledOtherRecording(otherSessionId: "b"))
    }

    // MARK: - showsStowControls (`docs/design/18-recording-window-stow-and-compact.md` §3.1)

    @Test("showsStowControls is true only for recording, paused, and pausedDisabledOtherRecording")
    func showsStowControlsTrueCases() {
        #expect(RecordingButtonState.recording(elapsedSeconds: 42).showsStowControls)
        #expect(RecordingButtonState.paused(elapsedSeconds: 42).showsStowControls)
        #expect(RecordingButtonState.pausedDisabledOtherRecording(elapsedSeconds: 42, otherSessionId: "session-1").showsStowControls)
    }

    @Test("showsStowControls is false for startRecording, every in-flight transition, disabledOtherRecording, and ended")
    func showsStowControlsFalseCases() {
        #expect(!RecordingButtonState.startRecording.showsStowControls)
        #expect(!RecordingButtonState.starting.showsStowControls)
        #expect(!RecordingButtonState.pausing.showsStowControls)
        #expect(!RecordingButtonState.resuming.showsStowControls)
        #expect(!RecordingButtonState.ending.showsStowControls)
        #expect(!RecordingButtonState.disabledOtherRecording(otherSessionId: "session-1").showsStowControls)
        #expect(!RecordingButtonState.ended.showsStowControls)
    }

    @Test("all cases are covered exhaustively by showsStowControls (no silent default)")
    func showsStowControlsAllCasesCovered() {
        let allCases: [RecordingButtonState] = [
            .startRecording,
            .starting,
            .recording(elapsedSeconds: 0),
            .pausing,
            .paused(elapsedSeconds: 0),
            .pausedDisabledOtherRecording(elapsedSeconds: 0, otherSessionId: "session-1"),
            .resuming,
            .ending,
            .disabledOtherRecording(otherSessionId: "session-1"),
            .ended
        ]
        let showing = Set(allCases.filter(\.showsStowControls).map(String.init(describing:)))
        let hidden = Set(allCases.filter { !$0.showsStowControls }.map(String.init(describing:)))

        #expect(showing.count == 3)
        #expect(hidden.count == 7)
        #expect(showing.isDisjoint(with: hidden))
    }

    // MARK: - elapsedSecondsForDisplay (`docs/design/18-recording-window-stow-and-compact.md` Major-1 fix)

    @Test("elapsedSecondsForDisplay returns the carried elapsedSeconds for recording, paused, and pausedDisabledOtherRecording")
    func elapsedSecondsForDisplayNonNilCases() {
        #expect(RecordingButtonState.recording(elapsedSeconds: 42).elapsedSecondsForDisplay == 42)
        #expect(RecordingButtonState.paused(elapsedSeconds: 7).elapsedSecondsForDisplay == 7)
        #expect(
            RecordingButtonState.pausedDisabledOtherRecording(elapsedSeconds: 13, otherSessionId: "session-1")
                .elapsedSecondsForDisplay == 13
        )
    }

    @Test("elapsedSecondsForDisplay is nil for every state without an elapsedSeconds, including the pausing/resuming transitions")
    func elapsedSecondsForDisplayNilCases() {
        #expect(RecordingButtonState.startRecording.elapsedSecondsForDisplay == nil)
        #expect(RecordingButtonState.starting.elapsedSecondsForDisplay == nil)
        #expect(RecordingButtonState.pausing.elapsedSecondsForDisplay == nil)
        #expect(RecordingButtonState.resuming.elapsedSecondsForDisplay == nil)
        #expect(RecordingButtonState.ending.elapsedSecondsForDisplay == nil)
        #expect(RecordingButtonState.disabledOtherRecording(otherSessionId: "session-1").elapsedSecondsForDisplay == nil)
        #expect(RecordingButtonState.ended.elapsedSecondsForDisplay == nil)
    }
}

// MARK: - WorkspaceBanner

@Suite("WorkspaceBanner")
struct WorkspaceBannerTests {
    @Test("id is stable and distinct across all banner cases, including associated values")
    func idDistinctAcrossCases() {
        let banners: [WorkspaceBanner] = [
            .systemAudioUnavailable(noActiveSourcesRemain: false),
            .fileWriteFailed(source: .mic),
            .fileWriteFailed(source: .system),
            .transcriptWriteFailed,
            .sttModelDownloading(source: .mic, progress: 0.5),
            .sttModelDownloadFailed(source: .mic, message: "boom"),
            .recordingStartFailed(message: "boom"),
            .builtInSpeakerOutputDetected
        ]
        let ids = banners.map(\.id)

        #expect(Set(ids).count == ids.count)
    }

    @Test("id ignores the continuously-varying progress value, unlike Equatable")
    func idIgnoresProgressValue() {
        // Two banners that differ only by a continuously-varying progress value would otherwise
        // thrash `Identifiable`-driven UI (e.g. SwiftUI List) on every progress tick if `id`
        // incorporated it. `id` must stay stable across progress ticks for the same source,
        // even though `Equatable`/`==` (which does incorporate progress) still distinguishes them.
        let first = WorkspaceBanner.sttModelDownloading(source: .mic, progress: 0.1)
        let second = WorkspaceBanner.sttModelDownloading(source: .mic, progress: 0.9)

        #expect(first.id == second.id)
        #expect(first != second)
    }

    @Test("Equatable distinguishes banners by their associated AudioSourceKind")
    func equatableDistinguishesSource() {
        #expect(WorkspaceBanner.fileWriteFailed(source: .mic) != .fileWriteFailed(source: .system))
    }

    @Test("id ignores noActiveSourcesRemain, unlike Equatable (docs/design/10-audio-input-selection.md section 5.2)")
    func idIgnoresNoActiveSourcesRemain() {
        let withMicRemaining = WorkspaceBanner.systemAudioUnavailable(noActiveSourcesRemain: false)
        let withNoSourcesRemaining = WorkspaceBanner.systemAudioUnavailable(noActiveSourcesRemain: true)

        #expect(withMicRemaining.id == withNoSourcesRemaining.id)
        #expect(withMicRemaining != withNoSourcesRemaining)
    }
}
