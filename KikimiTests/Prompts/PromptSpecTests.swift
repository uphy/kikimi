import CryptoKit
import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `PromptSpec.swift` (`docs/design/42-prompt-overrides.md` §2.1/§4.1): the
/// `PromptID` case set and its file-name-stem `rawValue`s, `PromptRef`'s id/path mapping and bundle-id
/// validation, and `PromptSpec.spec(for:)`'s per-id facts (`reload`, `requiredPlaceholders`,
/// `optionalPlaceholders`, `ejectComments`) plus `defaultBodyHash`'s hashing contract. Every other
/// `PromptSpec` test elsewhere in the suite exercises `defaultBody`/`defaultBodyHash` indirectly
/// through a consumer (`PromptFileTests`, `PromptStoreTests`, `PromptCLITests`, ...); this file is the
/// one place that pins down `PromptSpec`'s own facts directly, independent of any consumer.
@Suite("PromptSpec")
struct PromptSpecTests {
    // MARK: - PromptID

    @Test("PromptID.rawValue matches the file name stem documented in §2.1's table")
    func rawValueMatchesFileNameStem() {
        #expect(PromptID.refinement.rawValue == "refinement")
        #expect(PromptID.summary.rawValue == "summary")
        #expect(PromptID.finalTitle.rawValue == "final-title")
        #expect(PromptID.chat.rawValue == "chat")
        #expect(PromptID.simpleWatcher.rawValue == "simple-watcher")
        #expect(PromptID.glossaryHeader.rawValue == "glossary-header")
        #expect(PromptID.dictation.rawValue == "dictation")
        #expect(PromptID.summaryFinal.rawValue == "summary-final")
    }

    @Test("PromptID.allCases has exactly the 8 documented ids, no more, no fewer")
    func allCasesHasExactlyEightIds() {
        #expect(PromptID.allCases.count == 8)
        #expect(Set(PromptID.allCases) == [
            .refinement, .summary, .finalTitle, .chat, .simpleWatcher, .glossaryHeader, .dictation, .summaryFinal,
        ])
    }

    // MARK: - PromptRef.relativePath

    @Test("relativePath for a builtin ref is \"<rawValue>.md\", relative to prompts/")
    func builtinRelativePath() {
        #expect(PromptRef.builtin(.refinement).relativePath == "refinement.md")
        #expect(PromptRef.builtin(.simpleWatcher).relativePath == "simple-watcher.md")
        #expect(PromptRef.builtin(.finalTitle).relativePath == "final-title.md")
    }

    @Test("relativePath for a dictationApp ref is \"dictation/apps/<bundle-id>.md\"")
    func dictationAppRelativePath() {
        #expect(
            PromptRef.dictationApp(bundleID: "com.tinyspeck.slackmacgap").relativePath
                == "dictation/apps/com.tinyspeck.slackmacgap.md"
        )
    }

    // MARK: - PromptRef.isValidBundleID / init?(dictationAppBundleID:)

    @Test("isValidBundleID accepts letters, digits, '.', '_', '-'")
    func isValidBundleIDAcceptsAllowedCharacters() {
        #expect(PromptRef.isValidBundleID("com.tinyspeck.slackmacgap"))
        #expect(PromptRef.isValidBundleID("A1_b2-C3.d4"))
        #expect(PromptRef.isValidBundleID("a"))
    }

    @Test("isValidBundleID rejects an empty string")
    func isValidBundleIDRejectsEmpty() {
        #expect(!PromptRef.isValidBundleID(""))
    }

    @Test("isValidBundleID rejects characters outside [A-Za-z0-9._-], e.g. space, slash, and non-ASCII")
    func isValidBundleIDRejectsDisallowedCharacters() {
        #expect(!PromptRef.isValidBundleID("com example app"))
        #expect(!PromptRef.isValidBundleID("com/example/app"))
        #expect(!PromptRef.isValidBundleID("com.exämple.app"))
        #expect(!PromptRef.isValidBundleID("com.example.app😀"))
    }

    @Test("init?(dictationAppBundleID:) constructs .dictationApp for a valid bundle id")
    func initDictationAppBundleIDConstructsForValidInput() {
        let ref = PromptRef(dictationAppBundleID: "com.example.App")
        #expect(ref == .dictationApp(bundleID: "com.example.App"))
    }

    @Test("init?(dictationAppBundleID:) returns nil for an invalid bundle id")
    func initDictationAppBundleIDReturnsNilForInvalidInput() {
        #expect(PromptRef(dictationAppBundleID: "") == nil)
        #expect(PromptRef(dictationAppBundleID: "has space") == nil)
    }

    // MARK: - PromptSpec.spec(for:) per-id facts

    @Test("spec(for:).id always equals the id passed in")
    func specIdMatchesRequestedId() {
        for id in PromptID.allCases {
            #expect(PromptSpec.spec(for: id).id == id)
        }
    }

    @Test("reload: refinement and simple-watcher are session-start; every other id is immediate (§5.2's table)")
    func reloadMatchesDesignTable() {
        #expect(PromptSpec.spec(for: .refinement).reload == .sessionStart)
        #expect(PromptSpec.spec(for: .simpleWatcher).reload == .sessionStart)

        for id in [PromptID.summary, .finalTitle, .chat, .glossaryHeader, .dictation, .summaryFinal] {
            #expect(PromptSpec.spec(for: id).reload == .immediate, "\(id) must be .immediate")
        }
    }

    @Test("spec(for: .summaryFinal) is resolvable and matches §7.4's facts: immediate reload, no required/optional placeholders, no eject comments")
    func summaryFinalSpecMatchesDesignFacts() {
        let spec = PromptSpec.spec(for: .summaryFinal)
        #expect(spec.id == .summaryFinal)
        #expect(spec.reload == .immediate)
        #expect(spec.requiredPlaceholders.isEmpty)
        #expect(spec.optionalPlaceholders.isEmpty)
        #expect(spec.ejectComments.isEmpty)
        #expect(!spec.defaultBody.isEmpty)
    }

    @Test("requiredPlaceholders: only simple-watcher requires {{viewpoint}}; every other id requires none")
    func requiredPlaceholdersMatchesDesignTable() {
        #expect(PromptSpec.spec(for: .simpleWatcher).requiredPlaceholders == ["{{viewpoint}}"])

        for id in PromptID.allCases where id != .simpleWatcher {
            #expect(PromptSpec.spec(for: id).requiredPlaceholders.isEmpty, "\(id) must require no placeholders")
        }
    }

    @Test("optionalPlaceholders: only refinement recognizes {{leak_dedup_rule}}; every other id recognizes none")
    func optionalPlaceholdersMatchesDesignTable() {
        #expect(PromptSpec.spec(for: .refinement).optionalPlaceholders == ["{{leak_dedup_rule}}"])

        for id in PromptID.allCases where id != .refinement {
            #expect(PromptSpec.spec(for: id).optionalPlaceholders.isEmpty, "\(id) must have no optional placeholders")
        }
    }

    @Test("ejectComments: only simple-watcher carries an eject warning; every other id has none")
    func ejectCommentsMatchesDesignTable() {
        #expect(!PromptSpec.spec(for: .simpleWatcher).ejectComments.isEmpty)

        for id in PromptID.allCases where id != .simpleWatcher {
            #expect(PromptSpec.spec(for: id).ejectComments.isEmpty, "\(id) must have no eject comments")
        }
    }

    @Test("every id's defaultBody is non-empty")
    func defaultBodyIsNeverEmpty() {
        for id in PromptID.allCases {
            #expect(!PromptSpec.spec(for: id).defaultBody.isEmpty, "\(id)'s defaultBody must not be empty")
        }
    }

    @Test("simple-watcher's defaultBody contains the {{viewpoint}} placeholder it declares required")
    func simpleWatcherDefaultBodyContainsItsRequiredPlaceholder() {
        #expect(PromptSpec.spec(for: .simpleWatcher).defaultBody.contains("{{viewpoint}}"))
    }

    @Test("refinement's defaultBody contains the {{leak_dedup_rule}} placeholder it declares optional")
    func refinementDefaultBodyContainsItsOptionalPlaceholder() {
        #expect(PromptSpec.spec(for: .refinement).defaultBody.contains("{{leak_dedup_rule}}"))
    }

    @Test("summary's defaultBody includes §5.2's decision-qualification, decision-revision, and topic-scoping bullets")
    func summaryDefaultBodyIncludesDesignSection52Bullets() {
        let body = PromptSpec.spec(for: .summary).defaultBody
        #expect(body.contains("認識共有・現状理解の確認・可能性やアイデアの言及・単なる進捗報告は decision に入れない"))
        #expect(body.contains("decisions_modify"))
        #expect(body.contains("decisions_remove"))
        #expect(body.contains("topics_update"))
    }

    @Test("summary-final's defaultBody includes §7.4's whole-meeting overview, decision-validity, and done-preservation bullets")
    func summaryFinalDefaultBodyIncludesDesignSection74Bullets() {
        let body = PromptSpec.spec(for: .summaryFinal).defaultBody
        #expect(body.contains("会議全体を俯瞰した要約"))
        #expect(body.contains("会議終了時点で有効な決定だけを残す"))
        #expect(body.contains("done"))
    }

    // MARK: - defaultBodyHash

    @Test("defaultBodyHash returns a 12-character lowercase hex string")
    func defaultBodyHashIsTwelveLowercaseHexCharacters() {
        let hash = PromptSpec.defaultBodyHash(.refinement)
        #expect(hash.count == 12)
        #expect(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("defaultBodyHash is deterministic: repeated calls for the same id produce the same hash")
    func defaultBodyHashIsDeterministic() {
        #expect(PromptSpec.defaultBodyHash(.summary) == PromptSpec.defaultBodyHash(.summary))
    }

    @Test("defaultBodyHash is SHA-256(defaultBody UTF-8 bytes), truncated to its first 12 hex characters")
    func defaultBodyHashMatchesManualSHA256Computation() {
        for id in PromptID.allCases {
            let digest = SHA256.hash(data: Data(PromptSpec.spec(for: id).defaultBody.utf8))
            let expected = String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
            #expect(PromptSpec.defaultBodyHash(id) == expected, "\(id)'s hash must be its default body's SHA-256 prefix")
        }
    }

    @Test("defaultBodyHash differs across ids with different default bodies (no accidental collision)")
    func defaultBodyHashDiffersAcrossIds() {
        let hashes = PromptID.allCases.map { PromptSpec.defaultBodyHash($0) }
        #expect(Set(hashes).count == hashes.count)
    }

    // MARK: - PromptReload

    @Test("PromptReload.rawValue matches the frontmatter literal a `.md` file's \"reload:\" field uses")
    func promptReloadRawValueMatchesFrontmatterLiteral() {
        #expect(PromptReload.immediate.rawValue == "immediate")
        #expect(PromptReload.sessionStart.rawValue == "session-start")
    }
}
