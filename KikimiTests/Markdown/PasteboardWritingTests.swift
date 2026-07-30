import AppKit
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `SystemPasteboard` (`Kikimi/Markdown/PasteboardWriting.swift`),
/// the production `PasteboardWriting` implementation used by `MeetingWorkspaceViewModel`'s and
/// `SessionListViewModel`'s "copy transcript as Markdown" feature
/// (`docs/design/37-transcript-markdown-copy.md` §3.3, TC10).
///
/// These tests exercise the real `NSPasteboard.general` (there is no fake/in-memory pasteboard
/// to substitute -- `SystemPasteboard` exists precisely so *other* types can inject a fake
/// `PasteboardWriting` instead of touching the system pasteboard directly). Every test saves the
/// pasteboard's prior contents up front and restores them in a `defer`, so running the suite
/// does not clobber whatever the developer had copied before running tests.
@Suite("PasteboardWriting", .serialized)
struct PasteboardWritingTests {
    /// Snapshot of everything `NSPasteboard.general` held before a test ran, restored via
    /// `restore()` so the suite leaves the system pasteboard exactly as it found it.
    private struct SavedPasteboardContents {
        let items: [NSPasteboardItem]

        static func capture() -> SavedPasteboardContents {
            let pasteboard = NSPasteboard.general
            let items = (pasteboard.pasteboardItems ?? []).map { original -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in original.types {
                    if let data = original.data(forType: type) {
                        copy.setData(data, forType: type)
                    }
                }
                return copy
            }
            return SavedPasteboardContents(items: items)
        }

        func restore() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            pasteboard.writeObjects(items)
        }
    }

    /// TC10 core behavior: `writeString` places `string` on `NSPasteboard.general` as plain
    /// `.string` content and reports success.
    @Test("writeString writes the given string to NSPasteboard.general and returns true")
    func writeStringWritesToGeneralPasteboardAndReturnsTrue() {
        let saved = SavedPasteboardContents.capture()
        defer { saved.restore() }

        let pasteboard = SystemPasteboard()
        let result = pasteboard.writeString("# 見出し\n\n本文テキスト")

        #expect(result == true)
        #expect(NSPasteboard.general.string(forType: .string) == "# 見出し\n\n本文テキスト")
    }

    /// `writeString` calls `clearContents()` before writing (design: "`NSPasteboard.general` に
    /// `.string` を書くだけ"), so any unrelated types left over from a prior pasteboard write
    /// (e.g. RTF, a custom UTI) must be gone afterward -- not just the `.string` type replaced.
    @Test("writeString clears pre-existing pasteboard contents before writing")
    func writeStringClearsPriorContentsBeforeWriting() {
        let saved = SavedPasteboardContents.capture()
        defer { saved.restore() }

        let staleType = NSPasteboard.PasteboardType("io.github.uphy.kikimi.test.stale")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("stale value", forType: staleType)
        NSPasteboard.general.setString("stale plain text", forType: .string)

        let pasteboard = SystemPasteboard()
        _ = pasteboard.writeString("new value")

        #expect(NSPasteboard.general.string(forType: staleType) == nil)
        #expect(NSPasteboard.general.string(forType: .string) == "new value")
    }

    /// Design §3.3/TC10: unlike `DictationInserter`'s transient pasteboard round-trip
    /// (`Kikimi/Dictation/DictationInserter.swift`), a user-requested copy must stay visible to
    /// clipboard history tools, so `SystemPasteboard` must never tag its write with
    /// `org.nspasteboard.ConcealedType`.
    @Test("writeString does not tag the write with the ConcealedType marker")
    func writeStringDoesNotSetConcealedTypeMarker() {
        let saved = SavedPasteboardContents.capture()
        defer { saved.restore() }

        let pasteboard = SystemPasteboard()
        _ = pasteboard.writeString("視認可能なコピー")

        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        #expect(NSPasteboard.general.data(forType: concealedType) == nil)
    }

    /// Writing an empty string is a degenerate but valid input (e.g. copying an empty
    /// transcript selection) -- it must still succeed and leave the pasteboard holding an empty
    /// string rather than failing or leaving stale content behind.
    @Test("writeString succeeds for an empty string")
    func writeStringSucceedsForEmptyString() {
        let saved = SavedPasteboardContents.capture()
        defer { saved.restore() }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("previous content", forType: .string)

        let pasteboard = SystemPasteboard()
        let result = pasteboard.writeString("")

        #expect(result == true)
        #expect(NSPasteboard.general.string(forType: .string) == "")
    }

    /// Two consecutive writes must not accumulate -- the second call's content fully replaces
    /// the first's, matching `clearContents()` running on every call.
    @Test("a second writeString call replaces the first call's content")
    func secondWriteStringReplacesFirstCallContent() {
        let saved = SavedPasteboardContents.capture()
        defer { saved.restore() }

        let pasteboard = SystemPasteboard()
        _ = pasteboard.writeString("first")
        let result = pasteboard.writeString("second")

        #expect(result == true)
        #expect(NSPasteboard.general.string(forType: .string) == "second")
    }
}
