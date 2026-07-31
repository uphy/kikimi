import Foundation

// MARK: - MeetingProfileIdValidation

/// Shared id-character validator for meeting profiles (`docs/design/41-meeting-profiles.md` §2.1:
/// "profile id はディレクトリ名。文字種は session-local Watcher id と同じ `[A-Za-z0-9-]+`").
///
/// Unlike the per-file `private` duplicates of this exact character rule elsewhere in the codebase
/// (`WatcherLibrary.isValidWatcherId(_:)`, `MeetingWorkspaceViewModel+Watchers.swift`'s
/// `isValidLocalWatcherId(_:)` -- each kept `private` and re-implemented on purpose, per their own
/// doc comments, because each caller needed the check before it had a shared place to put it), this
/// one is deliberately a standalone, non-private helper: §3.2/§5 call for the *same* profile-id
/// validation from multiple independent call sites (`MeetingProfileStore.save(_:overwrite:)`, the
/// "プロファイルとして保存…" sheet's inline validation, and any future URL-scheme id parsing), and
/// none of those sit inside one another's file the way the Watcher duplicates do. This is a fresh
/// implementation (not a re-export of either `private` Watcher validator) so this file has no
/// dependency on `Kikimi/Watchers/` or `Kikimi/ViewModels/`.
enum MeetingProfileIdValidation {
    /// `true` iff `id` is non-empty and every character is an ASCII letter, digit, or hyphen.
    static func validate(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(Character(scalar)) ||
                ("A"..."Z").contains(Character(scalar)) ||
                ("0"..."9").contains(Character(scalar)) ||
                scalar == "-"
        }
    }
}
