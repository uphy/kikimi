import Foundation
import Testing

@testable import Kikimi

// MARK: - SessionListContextMenuAvailability

/// Unit tests for `SessionListContextMenuAvailability` (`Kikimi/Views/SessionListView.swift`),
/// which its own doc comment calls out as factored out of `SessionListView.contextMenuItems(for:)`
/// specifically so this logic "stays directly unit-testable without instantiating a SwiftUI view"
/// (`docs/design/06-ui-panels.md` section 7: right-click menu availability mirrors the footer's
/// buttons).
@Suite("SessionListContextMenuAvailability")
struct SessionListContextMenuAvailabilityTests {
    // MARK: canActOnSingleSelection(_:) — "開く" / "複製して新規セッション" / "Markdown をコピー"

    @Test("disabled when no session is selected")
    func singleSelectionDisabledWhenEmpty() {
        #expect(SessionListContextMenuAvailability.canActOnSingleSelection([]) == false)
    }

    @Test("enabled when exactly one session is selected")
    func singleSelectionEnabledForExactlyOne() {
        #expect(SessionListContextMenuAvailability.canActOnSingleSelection(["a"]) == true)
    }

    @Test("disabled when more than one session is selected")
    func singleSelectionDisabledForMultiple() {
        #expect(SessionListContextMenuAvailability.canActOnSingleSelection(["a", "b"]) == false)
        #expect(SessionListContextMenuAvailability.canActOnSingleSelection(["a", "b", "c"]) == false)
    }

    // MARK: canDelete(_:recordingSessionId:) — "削除"

    @Test("disabled when no session is selected, regardless of recordingSessionId")
    func deleteDisabledWhenSelectionEmpty() {
        #expect(SessionListContextMenuAvailability.canDelete([], recordingSessionId: nil) == false)
        #expect(SessionListContextMenuAvailability.canDelete([], recordingSessionId: "a") == false)
    }

    @Test("enabled for a single non-recording selection")
    func deleteEnabledForSingleNonRecordingSelection() {
        #expect(SessionListContextMenuAvailability.canDelete(["a"], recordingSessionId: nil) == true)
        #expect(SessionListContextMenuAvailability.canDelete(["a"], recordingSessionId: "b") == true)
    }

    @Test("enabled for a multi-selection that does not include the recording session")
    func deleteEnabledForMultiSelectionExcludingRecording() {
        #expect(SessionListContextMenuAvailability.canDelete(["a", "b", "c"], recordingSessionId: "z") == true)
        #expect(SessionListContextMenuAvailability.canDelete(["a", "b", "c"], recordingSessionId: nil) == true)
    }

    @Test("disabled when the single selected session is the recording session")
    func deleteDisabledForSingleRecordingSelection() {
        #expect(SessionListContextMenuAvailability.canDelete(["a"], recordingSessionId: "a") == false)
    }

    @Test("disabled when the recording session is anywhere inside a multi-selection")
    func deleteDisabledWhenRecordingSessionInsideMultiSelection() {
        #expect(SessionListContextMenuAvailability.canDelete(["a", "b", "c"], recordingSessionId: "b") == false)
    }
}

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
