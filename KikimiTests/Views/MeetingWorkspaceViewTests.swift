import Foundation
import Testing

@testable import Kikimi

// MARK: - TimeFormatting

/// Unit tests for `TimeFormatting.clock(seconds:)` (`Kikimi/Views/MeetingWorkspace/MeetingWorkspaceView.swift`),
/// the header's elapsed/total-duration display helper (`docs/design/06-ui-panels.md` section 6.1).
/// A pure function, so it's directly testable without any `NSPanel`/view-model machinery.
@Suite("TimeFormatting")
struct TimeFormattingTests {
    @Test("formats sub-minute durations as MM:SS")
    func formatsSubMinute() {
        #expect(TimeFormatting.clock(seconds: 0) == "00:00")
        #expect(TimeFormatting.clock(seconds: 5) == "00:05")
        #expect(TimeFormatting.clock(seconds: 59) == "00:59")
    }

    @Test("formats sub-hour durations as MM:SS, e.g. the header mockup's 25:12")
    func formatsSubHour() {
        #expect(TimeFormatting.clock(seconds: 60) == "01:00")
        #expect(TimeFormatting.clock(seconds: 25 * 60 + 12) == "25:12")
        #expect(TimeFormatting.clock(seconds: 3599) == "59:59")
    }

    @Test("switches to H:MM:SS once the duration reaches an hour")
    func switchesToHourFormatAtOneHour() {
        #expect(TimeFormatting.clock(seconds: 3600) == "1:00:00")
        #expect(TimeFormatting.clock(seconds: 3600 + 61) == "1:01:01")
    }

    @Test("hours are not zero-padded, but minutes/seconds within the hour format are")
    func hoursNotZeroPaddedMinutesSecondsAre() {
        #expect(TimeFormatting.clock(seconds: 10 * 3600 + 5 * 60 + 9) == "10:05:09")
    }

    @Test("clamps negative input to zero rather than producing a negative/garbled string")
    func clampsNegativeToZero() {
        #expect(TimeFormatting.clock(seconds: -1) == "00:00")
        #expect(TimeFormatting.clock(seconds: -3600) == "00:00")
    }
}
