import Foundation
import Testing

@testable import Kikimi

// MARK: - SessionListFormatting

/// Unit tests for `SessionListFormatting` (`Kikimi/Views/SessionListView.swift`), which its own doc
/// comment calls out as "pure display-formatting helpers, kept free of view state so they stay
/// directly unit-testable" (`docs/design/06-ui-panels.md` section 12).
@Suite("SessionListFormatting")
struct SessionListFormattingTests {
    // MARK: timestamp(_:)

    @Test("formats a date as yyyy-MM-dd HH:mm in a fixed locale/calendar, independent of the host's timezone")
    func formatsTimestampInFixedLocale() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: 2026, month: 7, day: 1, hour: 14, minute: 30)
        let date = calendar.date(from: components)!

        let formatted = SessionListFormatting.timestamp(date)

        // The formatter itself doesn't pin a timezone (only calendar/locale), so assert against a
        // formatter built the exact same way rather than hardcoding a wall-clock string that would
        // be sensitive to the machine running the tests.
        let expectedFormatter = DateFormatter()
        expectedFormatter.calendar = Calendar(identifier: .gregorian)
        expectedFormatter.locale = Locale(identifier: "en_US_POSIX")
        expectedFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        #expect(formatted == expectedFormatter.string(from: date))
    }

    // MARK: duration(_:)

    @Test("formats sub-hour durations as \"Nm\" with no hour component")
    func formatsSubHourDuration() {
        #expect(SessionListFormatting.duration(0) == "0m")
        #expect(SessionListFormatting.duration(60_000) == "1m")
        #expect(SessionListFormatting.duration(2_725_000) == "45m") // 45m25s -> floors to 45m
    }

    @Test("formats hour-plus durations as \"HhMMm\", zero-padding the minutes")
    func formatsHourPlusDuration() {
        #expect(SessionListFormatting.duration(3_600_000) == "1h00m")
        #expect(SessionListFormatting.duration(4_500_000) == "1h15m") // 75 minutes
        #expect(SessionListFormatting.duration(3_600_000 * 2 + 60_000 * 5) == "2h05m")
    }

    @Test("clamps negative milliseconds to zero rather than producing a negative duration")
    func clampsNegativeToZero() {
        #expect(SessionListFormatting.duration(-1) == "0m")
        #expect(SessionListFormatting.duration(-3_600_000) == "0m")
    }
}
