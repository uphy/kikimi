import CryptoKit
import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `PromptValidator` (`docs/design/42-prompt-overrides.md` §4.1/§6.2/§8,
/// `docs/prompts.md` "`--validate-prompts`"): the ERROR/WARN/STALE judgment `validate(fileText:ref:)`
/// makes for a single file, and the `validateAll(directory:)` walk's file discovery (including the
/// "無視される謎ファイル" WARN).
@Suite("PromptValidator")
struct PromptValidatorTests {
    // MARK: - helpers

    private func sha256Hex12(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// The current `based_on` hash for a builtin id's default body (§3.3) -- used to build
    /// frontmatter that is deliberately *not* stale, so a test can isolate a single other finding.
    private func currentHash(_ id: PromptID) -> String {
        PromptSpec.defaultBodyHash(id)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - ERROR: delegated to PromptFile.parse (§8 #3-#6)

    @Test("a file with no frontmatter delimiter is an ERROR finding, message delegated from PromptFileError")
    func missingFrontmatterIsError() {
        let findings = PromptValidator.validate(fileText: "no frontmatter here", ref: .builtin(.chat))
        #expect(findings.count == 1)
        #expect(findings[0].level == .error)
        #expect(findings[0].path == "prompts/chat.md")
        #expect(findings[0].message == PromptFileError.frontmatterMissing.errorDescription)
    }

    @Test("a \"prompt\" field that does not match the ref's id is an ERROR finding")
    func mismatchedPromptFieldIsError() {
        let text = "---\nprompt: summary\n---\n\n本文"
        let findings = PromptValidator.validate(fileText: text, ref: .builtin(.chat))
        #expect(findings == [
            PromptValidator.Finding(
                level: .error,
                path: "prompts/chat.md",
                message: PromptFileError.promptFieldMismatch(declared: "summary", expected: "chat").errorDescription!
            )
        ])
    }

    @Test("a missing required placeholder is an ERROR finding")
    func missingRequiredPlaceholderIsError() {
        let text = "---\nprompt: simple-watcher\n---\n\n観点の説明のみ、placeholderなし"
        let findings = PromptValidator.validate(fileText: text, ref: .builtin(.simpleWatcher))
        #expect(findings.count == 1)
        #expect(findings[0].level == .error)
        #expect(findings[0].message.contains("{{viewpoint}}"))
    }

    @Test("an empty body is an ERROR finding for an ordinary (non-dictation) id")
    func emptyBodyIsErrorForOrdinaryID() {
        let text = "---\nprompt: chat\n---\n\n   \n"
        let findings = PromptValidator.validate(fileText: text, ref: .builtin(.chat))
        #expect(findings == [
            PromptValidator.Finding(level: .error, path: "prompts/chat.md", message: PromptFileError.emptyBody.errorDescription!)
        ])
    }

    @Test("an ERROR short-circuits: no WARN findings are reported alongside it")
    func errorShortCircuitsOtherChecks() {
        // Deliberately wrong `based_on` (would be STALE) on a file that is also missing the
        // required placeholder (ERROR) -- only the ERROR should be reported.
        let text = "---\nprompt: simple-watcher\nbased_on: deadbeef0000\n---\n\n観点なし"
        let findings = PromptValidator.validate(fileText: text, ref: .builtin(.simpleWatcher))
        #expect(findings.count == 1)
        #expect(findings[0].level == .error)
    }

    // MARK: - a fully well-formed override has no findings

    @Test("a well-formed override built via PromptFile.render has no findings")
    func wellFormedOverrideHasNoFindings() {
        let spec = PromptSpec.spec(for: .chat)
        let text = PromptFile.render(id: "chat", spec: spec, body: "カスタムのシステムプロンプト本文です。")
        #expect(PromptValidator.validate(fileText: text, ref: .builtin(.chat)).isEmpty)
    }

    @Test("an empty body is valid (no findings) for \"dictation\" when based_on/reload are correct")
    func emptyBodyIsValidForDictation() {
        let hash = currentHash(.dictation)
        let text = """
        ---
        prompt: dictation
        based_on: \(hash)
        reload: immediate
        placeholders:
          required: []
          optional: []
        ---

        """
        #expect(PromptValidator.validate(fileText: text, ref: .builtin(.dictation)).isEmpty)
    }

    @Test("an empty body is valid (no findings) for a per-app dictation context")
    func emptyBodyIsValidForDictationApp() {
        let text = "---\nprompt: dictation/apps/com.microsoft.VSCode\n---\n\n"
        let ref = PromptRef.dictationApp(bundleID: "com.microsoft.VSCode")
        #expect(PromptValidator.validate(fileText: text, ref: ref).isEmpty)
    }

    // MARK: - WARN: based_on missing (§3.2, §8)

    @Test("a missing \"based_on\" field is a WARN finding for a builtin id")
    func missingBasedOnIsWarning() {
        let text = "---\nprompt: chat\nreload: immediate\n---\n\n本文です。"
        let findings = PromptValidator.validate(fileText: text, ref: .builtin(.chat))
        #expect(findings.count == 1)
        #expect(findings[0].level == .warning)
        #expect(findings[0].message.contains("based_on"))
    }

    @Test("a missing \"based_on\" field is not reported for a per-app dictation context (no default to compare against)")
    func missingBasedOnIsNotWarningForDictationApp() {
        let text = "---\nprompt: dictation/apps/com.example.App\n---\n\n追加指示の本文"
        let findings = PromptValidator.validate(fileText: text, ref: .dictationApp(bundleID: "com.example.App"))
        #expect(findings.isEmpty)
    }

    // MARK: - STALE: based_on hash mismatch (§3.3, §8 #9)

    @Test("a \"based_on\" that does not match the current default hash is a STALE finding, formatted \"based_on <hash> != current <hash>\"")
    func mismatchedBasedOnIsStale() {
        let text = "---\nprompt: chat\nbased_on: deadbeef0000\nreload: immediate\n---\n\n本文です。"
        let findings = PromptValidator.validate(fileText: text, ref: .builtin(.chat))
        let currentChatHash = currentHash(.chat)
        #expect(findings == [
            PromptValidator.Finding(
                level: .stale,
                path: "prompts/chat.md",
                message: "based_on deadbeef0000 != current \(currentChatHash)"
            )
        ])
    }

    @Test("STALE is never reported for a per-app dictation context")
    func staleIsNeverReportedForDictationApp() {
        // `based_on` has no meaning for a per-app file, so even an obviously bogus value is ignored.
        let text = "---\nprompt: dictation/apps/com.example.App\nbased_on: not-a-real-hash\n---\n\n本文"
        let findings = PromptValidator.validate(fileText: text, ref: .dictationApp(bundleID: "com.example.App"))
        #expect(findings.isEmpty)
    }

    // MARK: - WARN: reload drift (§3.2's frontmatter table)

    @Test("a \"reload\" value that disagrees with PromptSpec.reload is a WARN finding")
    func reloadDriftIsWarning() {
        let text = """
        ---
        prompt: chat
        based_on: \(currentHash(.chat))
        reload: session-start
        placeholders:
          required: []
          optional: []
        ---

        本文です。
        """
        let findings = PromptValidator.validate(fileText: text, ref: .builtin(.chat))
        #expect(findings.count == 1)
        #expect(findings[0].level == .warning)
        #expect(findings[0].message.contains("reload"))
    }

    @Test("a \"reload\" value that agrees with PromptSpec.reload produces no drift finding")
    func matchingReloadHasNoDriftFinding() {
        let text = """
        ---
        prompt: chat
        based_on: \(currentHash(.chat))
        reload: immediate
        placeholders:
          required: []
          optional: []
        ---

        本文です。
        """
        #expect(PromptValidator.validate(fileText: text, ref: .builtin(.chat)).isEmpty)
    }

    // MARK: - WARN: placeholders drift (§3.2's frontmatter table)

    @Test("a \"placeholders.required\" list that disagrees with PromptSpec.requiredPlaceholders is a WARN finding")
    func requiredPlaceholdersDriftIsWarning() {
        let text = """
        ---
        prompt: simple-watcher
        based_on: \(currentHash(.simpleWatcher))
        reload: session-start
        placeholders:
          required: []
          optional: []
        ---

        【観点】
        {{viewpoint}}
        """
        let findings = PromptValidator.validate(fileText: text, ref: .builtin(.simpleWatcher))
        #expect(findings.count == 1)
        #expect(findings[0].level == .warning)
        #expect(findings[0].message.contains("placeholders.required"))
    }

    @Test("a \"placeholders.optional\" list that disagrees with PromptSpec.optionalPlaceholders is a WARN finding")
    func optionalPlaceholdersDriftIsWarning() {
        let text = """
        ---
        prompt: refinement
        based_on: \(currentHash(.refinement))
        reload: session-start
        placeholders:
          required: []
          optional: []
        ---

        整形ルールの本文です。
        """
        let findings = PromptValidator.validate(fileText: text, ref: .builtin(.refinement))
        #expect(findings.count == 1)
        #expect(findings[0].level == .warning)
        #expect(findings[0].message.contains("placeholders.optional"))
    }

    @Test("matching placeholders.required/optional lists produce no drift finding")
    func matchingPlaceholdersHaveNoDriftFinding() {
        let text = """
        ---
        prompt: simple-watcher
        based_on: \(currentHash(.simpleWatcher))
        reload: session-start
        placeholders:
          required: ["{{viewpoint}}"]
          optional: []
        ---

        【観点】
        {{viewpoint}}
        """
        #expect(PromptValidator.validate(fileText: text, ref: .builtin(.simpleWatcher)).isEmpty)
    }

    // MARK: - WARN: unknown {{...}} placeholder tokens (§3.2, §8 #8)

    @Test("an unrecognized {{...}}-shaped token in the body is a WARN finding")
    func unknownPlaceholderTokenIsWarning() {
        let text = """
        ---
        prompt: chat
        based_on: \(currentHash(.chat))
        reload: immediate
        placeholders:
          required: []
          optional: []
        ---

        本文中に {{unknown_token}} が含まれます。
        """
        let findings = PromptValidator.validate(fileText: text, ref: .builtin(.chat))
        #expect(findings.count == 1)
        #expect(findings[0].level == .warning)
        #expect(findings[0].message.contains("{{unknown_token}}"))
    }

    @Test("a recognized optional placeholder token is not reported as unknown")
    func recognizedOptionalPlaceholderIsNotUnknown() {
        let text = """
        ---
        prompt: refinement
        based_on: \(currentHash(.refinement))
        reload: session-start
        placeholders:
          required: []
          optional: ["{{leak_dedup_rule}}"]
        ---

        整形ルール本文{{leak_dedup_rule}}です。
        """
        #expect(PromptValidator.validate(fileText: text, ref: .builtin(.refinement)).isEmpty)
    }

    @Test("a repeated unknown token is reported once, not once per occurrence")
    func repeatedUnknownTokenIsDeduplicated() {
        let text = """
        ---
        prompt: chat
        based_on: \(currentHash(.chat))
        reload: immediate
        placeholders:
          required: []
          optional: []
        ---

        {{dup}} と {{dup}} が二回出てきます。
        """
        let findings = PromptValidator.validate(fileText: text, ref: .builtin(.chat))
        #expect(findings.count == 1)
    }

    // MARK: - WARN: 32KB body clamp (§3.2, §8 #7)

    @Test("a body over 32KB UTF-8 bytes is a WARN finding, not an ERROR (still used, just clamped)")
    func oversizedBodyIsWarning() {
        let oversized = String(repeating: "あ", count: PromptFile.maxBodyBytes)
        let text = """
        ---
        prompt: chat
        based_on: \(currentHash(.chat))
        reload: immediate
        placeholders:
          required: []
          optional: []
        ---

        \(oversized)
        """
        let findings = PromptValidator.validate(fileText: text, ref: .builtin(.chat))
        #expect(findings.count == 1)
        #expect(findings[0].level == .warning)
        #expect(findings[0].message.contains("32KB"))
    }

    // MARK: - Level.label (§6.2)

    @Test("Level.label matches the documented CLI prefixes")
    func levelLabelsMatchCLIPrefixes() {
        #expect(PromptValidator.Level.error.label == "ERROR")
        #expect(PromptValidator.Level.warning.label == "WARN")
        #expect(PromptValidator.Level.stale.label == "STALE")
    }

    // MARK: - validateAll(directory:) file discovery

    @Test("validateAll on a directory with no override files produces no findings")
    func validateAllOnEmptyDirectoryHasNoFindings() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PromptValidator.validateAll(directory: root).isEmpty)
    }

    @Test("validateAll on a directory that does not exist produces no findings (no crash)")
    func validateAllOnMissingDirectoryHasNoFindings() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("PromptValidatorTests-missing-\(UUID().uuidString)")
        #expect(PromptValidator.validateAll(directory: missing).isEmpty)
    }

    @Test("validateAll validates every well-formed builtin override it finds")
    func validateAllValidatesWellFormedOverrides() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let spec = PromptSpec.spec(for: .chat)
        let text = PromptFile.render(id: "chat", spec: spec, body: "カスタム本文")
        try text.write(to: root.appendingPathComponent("chat.md"), atomically: true, encoding: .utf8)

        #expect(PromptValidator.validateAll(directory: root).isEmpty)
    }

    @Test("validateAll reports an ERROR finding for a broken builtin override it finds")
    func validateAllReportsErrorForBrokenOverride() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "not a valid override file".write(to: root.appendingPathComponent("chat.md"), atomically: true, encoding: .utf8)

        let findings = PromptValidator.validateAll(directory: root)
        #expect(findings == [
            PromptValidator.Finding(level: .error, path: "prompts/chat.md", message: PromptFileError.frontmatterMissing.errorDescription!)
        ])
    }

    @Test("validateAll reports a WARN for an unrecognized file directly under prompts/")
    func validateAllReportsWarningForUnrecognizedFile() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "irrelevant contents".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let findings = PromptValidator.validateAll(directory: root)
        #expect(findings.count == 1)
        #expect(findings[0].level == .warning)
        #expect(findings[0].path == "prompts/notes.txt")
    }

    @Test("validateAll reports a WARN for a .md file whose name is not one of the 7 known ids")
    func validateAllReportsWarningForUnrecognizedMdFile() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "irrelevant".write(to: root.appendingPathComponent("typo-refinement.md"), atomically: true, encoding: .utf8)

        let findings = PromptValidator.validateAll(directory: root)
        #expect(findings.count == 1)
        #expect(findings[0].level == .warning)
        #expect(findings[0].path == "prompts/typo-refinement.md")
    }

    @Test("validateAll reports a WARN for an unrecognized subdirectory directly under prompts/")
    func validateAllReportsWarningForUnrecognizedSubdirectory() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("extra"), withIntermediateDirectories: true)

        let findings = PromptValidator.validateAll(directory: root)
        #expect(findings.count == 1)
        #expect(findings[0].level == .warning)
        #expect(findings[0].path == "prompts/extra/")
    }

    @Test("validateAll validates well-formed per-app dictation overrides under prompts/dictation/apps/")
    func validateAllValidatesDictationAppOverrides() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appsDirectory = root.appendingPathComponent("dictation", isDirectory: true).appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: appsDirectory, withIntermediateDirectories: true)
        let text = "---\nprompt: dictation/apps/com.microsoft.VSCode\n---\n\nVSCode向けの追加指示"
        try text.write(to: appsDirectory.appendingPathComponent("com.microsoft.VSCode.md"), atomically: true, encoding: .utf8)

        #expect(PromptValidator.validateAll(directory: root).isEmpty)
    }

    @Test("validateAll reports a WARN for a dictation/apps/ file name that is not a valid bundle id")
    func validateAllReportsWarningForInvalidBundleID() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appsDirectory = root.appendingPathComponent("dictation", isDirectory: true).appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: appsDirectory, withIntermediateDirectories: true)
        try "本文".write(to: appsDirectory.appendingPathComponent("not a bundle id!.md"), atomically: true, encoding: .utf8)

        let findings = PromptValidator.validateAll(directory: root)
        #expect(findings.count == 1)
        #expect(findings[0].level == .warning)
        #expect(findings[0].path == "prompts/dictation/apps/not a bundle id!.md")
    }

    @Test("validateAll reports a WARN for a file directly under prompts/dictation/ (not inside apps/)")
    func validateAllReportsWarningForStrayFileUnderDictationDirectory() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dictationDirectory = root.appendingPathComponent("dictation", isDirectory: true)
        try FileManager.default.createDirectory(at: dictationDirectory, withIntermediateDirectories: true)
        try "本文".write(to: dictationDirectory.appendingPathComponent("stray.md"), atomically: true, encoding: .utf8)

        let findings = PromptValidator.validateAll(directory: root)
        #expect(findings.count == 1)
        #expect(findings[0].level == .warning)
        #expect(findings[0].path == "prompts/dictation/stray.md")
    }

    @Test("validateAll aggregates findings across multiple files, in stable file-name order")
    func validateAllAggregatesFindingsInOrder() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "broken".write(to: root.appendingPathComponent("chat.md"), atomically: true, encoding: .utf8)
        try "irrelevant".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let refinementText = PromptFile.render(id: "refinement", spec: PromptSpec.spec(for: .refinement), body: "整形ルール本文")
        try refinementText.write(to: root.appendingPathComponent("refinement.md"), atomically: true, encoding: .utf8)

        let findings = PromptValidator.validateAll(directory: root)
        // "chat.md" and "notes.txt" sort before "refinement.md" -- one finding from each of the two
        // broken/unrecognized files, and none from the well-formed "refinement.md".
        #expect(findings.count == 2)
        #expect(findings[0].path == "prompts/chat.md")
        #expect(findings[0].level == .error)
        #expect(findings[1].path == "prompts/notes.txt")
        #expect(findings[1].level == .warning)
    }
}
