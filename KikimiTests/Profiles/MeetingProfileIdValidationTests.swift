import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `MeetingProfileIdValidation.validate(_:)`
/// (`Kikimi/Profiles/MeetingProfileIdValidation.swift`, `docs/design/41-meeting-profiles.md` §2.1:
/// "profile id はディレクトリ名。文字種は session-local Watcher id と同じ `[A-Za-z0-9-]+`"). This is a
/// pure character-class predicate with no I/O, so every case here runs against the function directly
/// rather than through `MeetingProfileStore`/`SessionStore` (which only incidentally exercise a
/// handful of these ids as fixtures for their own, different concerns).
@Suite("MeetingProfileIdValidation")
struct MeetingProfileIdValidationTests {
    // MARK: - Accepted

    @Test("accepts every individual character class the rule allows: lowercase, uppercase, digits, hyphen")
    func acceptsEachAllowedCharacterClass() {
        #expect(MeetingProfileIdValidation.validate("abcxyz"))
        #expect(MeetingProfileIdValidation.validate("ABCXYZ"))
        #expect(MeetingProfileIdValidation.validate("0123456789"))
        #expect(MeetingProfileIdValidation.validate("-"))
    }

    @Test("accepts a realistic mixed id, a single character, and a purely numeric id")
    func acceptsRealisticIds() {
        #expect(MeetingProfileIdValidation.validate("daily-scrum"))
        #expect(MeetingProfileIdValidation.validate("one-on-1-Weekly"))
        #expect(MeetingProfileIdValidation.validate("a"))
        #expect(MeetingProfileIdValidation.validate("123"))
    }

    @Test("accepts an id that starts or ends with a hyphen (the rule has no positional restriction)")
    func acceptsLeadingOrTrailingHyphen() {
        #expect(MeetingProfileIdValidation.validate("-leading"))
        #expect(MeetingProfileIdValidation.validate("trailing-"))
        #expect(MeetingProfileIdValidation.validate("--both--"))
    }

    // MARK: - Rejected

    @Test("rejects the empty string")
    func rejectsEmptyString() {
        #expect(!MeetingProfileIdValidation.validate(""))
    }

    @Test("rejects whitespace, including an id that is otherwise valid but has a trailing space")
    func rejectsWhitespace() {
        #expect(!MeetingProfileIdValidation.validate(" "))
        #expect(!MeetingProfileIdValidation.validate("daily-scrum "))
        #expect(!MeetingProfileIdValidation.validate(" daily-scrum"))
        #expect(!MeetingProfileIdValidation.validate("daily scrum"))
    }

    @Test("rejects path-separator characters, so a validated id can never escape profiles.dir when appended as a path component")
    func rejectsPathSeparators() {
        #expect(!MeetingProfileIdValidation.validate("a/b"))
        #expect(!MeetingProfileIdValidation.validate("../escape"))
        #expect(!MeetingProfileIdValidation.validate(".."))
        #expect(!MeetingProfileIdValidation.validate("."))
    }

    @Test("rejects underscore, unlike the hyphen it superficially resembles")
    func rejectsUnderscore() {
        #expect(!MeetingProfileIdValidation.validate("daily_scrum"))
    }

    @Test("rejects non-ASCII letters, including a fully Japanese id (display name is the id's own name field, not the id itself, §2.1)")
    func rejectsNonASCIILetters() {
        #expect(!MeetingProfileIdValidation.validate("デイリースクラム"))
        #expect(!MeetingProfileIdValidation.validate("daily-scrum-café"))
    }

    @Test("rejects other punctuation that is not a hyphen")
    func rejectsOtherPunctuation() {
        for id in ["a.b", "a!b", "a b", "a@b", "a#b", "a_b", "a:b", "a;b", "a,b"] {
            #expect(!MeetingProfileIdValidation.validate(id), "expected \"\(id)\" to be rejected")
        }
    }
}
