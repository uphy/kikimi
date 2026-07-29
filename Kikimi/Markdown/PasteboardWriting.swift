import AppKit

// MARK: - PasteboardWriting

/// DI seam for the transcript Markdown copy feature (`docs/design/37-transcript-markdown-copy.md`
/// §3.3, TC10), injected into `MeetingWorkspaceViewModel`/`SessionListViewModel` as a plain value so
/// both can be exercised in tests without touching the real `NSPasteboard.general`.
///
/// `Sendable` is required because the same value is captured by both view models and must remain
/// usable from non-main-actor call sites (`SessionListViewModel.copyMarkdown` and the disk adapter
/// path both run off the main actor).
protocol PasteboardWriting: Sendable {
    /// Writes `string` to the pasteboard, replacing any existing contents.
    ///
    /// - Returns: `false` if the underlying write failed (design §6); callers use this to decide
    ///   whether to show success feedback (checkmark / toast) or an error.
    @discardableResult
    func writeString(_ string: String) -> Bool
}

// MARK: - SystemPasteboard

/// Production `PasteboardWriting`. Writes to `NSPasteboard.general` as a normal, user-visible copy.
///
/// Unlike `DictationInserter`'s pasteboard round-trip (`Kikimi/Dictation/DictationInserter.swift:134`),
/// this does **not** tag the write with `org.nspasteboard.ConcealedType`. That marker exists to hide
/// an app's *incidental* pasteboard use (paste-insertion plumbing) from clipboard history tools. Here
/// the pasteboard write *is* the user-requested action -- the user explicitly clicked/pressed copy --
/// so it should show up in clipboard history like any other copy (design §3.3, TC10).
struct SystemPasteboard: PasteboardWriting {
    @discardableResult
    func writeString(_ string: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }
}
