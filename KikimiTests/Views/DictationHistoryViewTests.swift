import Foundation
import Testing

@testable import Kikimi

// MARK: - DictationHistoryFormatting

/// Unit tests for `DictationHistoryFormatting` (`Kikimi/Views/DictationHistoryView.swift`), which its
/// own doc comment calls out as "pure display-formatting helpers, kept free of view state so they
/// stay directly unit-testable" (`docs/design/29-dictation-history.md` section 6.2, mirroring
/// `SessionListFormatting`'s rationale).
@Suite("DictationHistoryFormatting")
struct DictationHistoryFormattingTests {
    // MARK: absolute(_:)

    @Test("formats a date as yyyy-MM-dd HH:mm:ss in a fixed locale/calendar, independent of the host's timezone")
    func formatsAbsoluteInFixedLocale() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: 2026, month: 7, day: 10, hour: 9, minute: 15, second: 32)
        let date = calendar.date(from: components)!

        let formatted = DictationHistoryFormatting.absolute(date)

        // The formatter itself doesn't pin a timezone (only calendar/locale), so assert against a
        // formatter built the exact same way rather than hardcoding a wall-clock string that would
        // be sensitive to the machine running the tests.
        let expectedFormatter = DateFormatter()
        expectedFormatter.calendar = Calendar(identifier: .gregorian)
        expectedFormatter.locale = Locale(identifier: "en_US_POSIX")
        expectedFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        #expect(formatted == expectedFormatter.string(from: date))
    }

    @Test("absolute(_:) carries second-resolution, unlike SessionListFormatting.timestamp's minute-resolution")
    func absoluteDistinguishesEntriesWithinTheSameMinute() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let first = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 9, minute: 15, second: 1))!
        let second = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 9, minute: 15, second: 32))!

        #expect(DictationHistoryFormatting.absolute(first) != DictationHistoryFormatting.absolute(second))
    }

    // MARK: relative(_:)

    @Test("relative(_:) produces a non-empty localized string for a past date")
    func relativeProducesNonEmptyString() {
        let past = Date(timeIntervalSinceNow: -60 * 5)

        let formatted = DictationHistoryFormatting.relative(past)

        #expect(!formatted.isEmpty)
    }

    // MARK: duration(_:)

    @Test("formats milliseconds as m:ss, zero-padding seconds")
    func formatsDurationAsMinutesSeconds() {
        #expect(DictationHistoryFormatting.duration(0) == "0:00")
        #expect(DictationHistoryFormatting.duration(4_210) == "0:04")
        #expect(DictationHistoryFormatting.duration(65_000) == "1:05")
    }

    @Test("floors sub-second remainders rather than rounding")
    func flooresSubSecondRemainder() {
        #expect(DictationHistoryFormatting.duration(1_999) == "0:01")
    }

    @Test("renders minutes without an hour component even for long durations, unlike SessionListFormatting.duration")
    func rendersMinutesWithoutHourComponentForLongDurations() {
        // 75 minutes: SessionListFormatting.duration would render "1h15m"; dictation utterances are
        // short, so this always stays in m:ss.
        #expect(DictationHistoryFormatting.duration(75 * 60 * 1_000) == "75:00")
    }

    @Test("clamps negative milliseconds to zero rather than producing a negative duration")
    func clampsNegativeToZero() {
        #expect(DictationHistoryFormatting.duration(-1) == "0:00")
        #expect(DictationHistoryFormatting.duration(-4_210) == "0:00")
    }
}
