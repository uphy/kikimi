import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `DictationElapsedTimeFormatter.format(seconds:)` -- the live-preview HUD's
/// pure `m:ss` formatter (`docs/design/25-dictation-mode.md`'s "ライブプレビューHUD" section).
@Suite("DictationElapsedTimeFormatter")
struct DictationElapsedTimeFormatterTests {
    @Test(
        "formats whole seconds as m:ss",
        arguments: [
            (0, "0:00"),
            (6, "0:06"),
            (9, "0:09"),
            (10, "0:10"),
            (59, "0:59"),
            (60, "1:00"),
            (65, "1:05"),
            (599, "9:59"),
            (600, "10:00"),
            (3_599, "59:59"),
            (3_600, "60:00")
        ]
    )
    func formatsWholeSeconds(seconds: Int, expected: String) {
        #expect(DictationElapsedTimeFormatter.format(seconds: seconds) == expected)
    }

    @Test("negative input clamps to 0:00 instead of emitting a negative string")
    func negativeInputClampsToZero() {
        #expect(DictationElapsedTimeFormatter.format(seconds: -5) == "0:00")
    }
}
