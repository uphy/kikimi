import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `PromptCLI` (`docs/design/42-prompt-overrides.md` §6): argument parsing /
/// GUI fallthrough, and each subcommand's exit codes. Every test roots the CLI at a fresh temporary
/// directory (`--prompts-dir`) so nothing here ever touches the real `~/.config/kikimi/prompts`
/// (mirrors `AppConfigTests`'s own DI convention).
@Suite("PromptCLI")
struct PromptCLITests {
    // MARK: - Test helpers

    private final class LineBuffer {
        private(set) var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
        var joined: String { lines.joined(separator: "\n") }
    }

    private func makeIO() -> (io: PromptCLI.IO, stdout: LineBuffer, stderr: LineBuffer) {
        let stdout = LineBuffer()
        let stderr = LineBuffer()
        let io = PromptCLI.IO(stdout: { stdout.append($0) }, stderr: { stderr.append($0) })
        return (io, stdout, stderr)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptCLITests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(_ arguments: [String], in directory: URL) -> (code: Int32?, stdout: LineBuffer, stderr: LineBuffer) {
        let (io, stdout, stderr) = makeIO()
        let code = PromptCLI.runIfRequested(arguments: ["--prompts-dir", directory.path] + arguments, io: io)
        return (code, stdout, stderr)
    }

    // MARK: - Argument parsing / GUI fallthrough (§6.1)

    @Test("no arguments falls through to the GUI launch (nil)")
    func noArgumentsFallsThrough() {
        #expect(PromptCLI.runIfRequested(arguments: []) == nil)
    }

    @Test("only unknown / macOS-injected flags fall through to the GUI launch (nil)")
    func unknownFlagsFallThrough() {
        #expect(PromptCLI.runIfRequested(arguments: ["-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        #expect(PromptCLI.runIfRequested(arguments: ["-psn_0_123456"]) == nil)
    }

    @Test("a recognized subcommand flag alongside unknown flags is still claimed (not nil)")
    func recognizedSubcommandAmongUnknownFlagsIsClaimed() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (io, _, _) = makeIO()
        let code = PromptCLI.runIfRequested(
            arguments: ["-NSDocumentRevisionsDebugMode", "YES", "--list-prompts", "--prompts-dir", dir.path],
            io: io
        )
        #expect(code == 0)
    }

    @Test("--eject-prompt with a missing <id> is a usage error (exit 1)")
    func ejectMissingIdIsUsageError() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--eject-prompt"], in: dir)
        #expect(result.code == 1)
        #expect(!result.stderr.lines.isEmpty)
    }

    @Test("--render-prompt with a missing <id> is a usage error (exit 1)")
    func renderMissingIdIsUsageError() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--render-prompt"], in: dir)
        #expect(result.code == 1)
        #expect(!result.stderr.lines.isEmpty)
    }

    // MARK: - --eject-prompt (§6.2)

    @Test("ejecting a built-in id writes prompts/<id>.md and prints its path, exit 0")
    func ejectBuiltinIdWritesFileAndPrintsPath() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--eject-prompt", "refinement"], in: dir)
        #expect(result.code == 0)

        let expectedPath = dir.appendingPathComponent("refinement.md").path
        #expect(result.stdout.lines == [expectedPath])
        #expect(FileManager.default.fileExists(atPath: expectedPath))

        let contents = (try? String(contentsOfFile: expectedPath, encoding: .utf8)) ?? ""
        #expect(contents.contains("prompt: refinement"))
        #expect(contents.contains(PromptSpec.spec(for: .refinement).defaultBody))
    }

    @Test("ejecting over an existing override without --force fails (exit 2) and leaves the file untouched")
    func ejectExistingWithoutForceFails() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = run(["--eject-prompt", "refinement"], in: dir)
        #expect(first.code == 0)

        let path = dir.appendingPathComponent("refinement.md").path
        let before = try? String(contentsOfFile: path, encoding: .utf8)

        let second = run(["--eject-prompt", "refinement"], in: dir)
        #expect(second.code == 2)
        #expect(!second.stderr.lines.isEmpty)

        let after = try? String(contentsOfFile: path, encoding: .utf8)
        #expect(before == after)
    }

    @Test("ejecting over an existing override with --force overwrites it (exit 0)")
    func ejectExistingWithForceOverwrites() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(run(["--eject-prompt", "refinement"], in: dir).code == 0)
        let result = run(["--eject-prompt", "refinement", "--force"], in: dir)
        #expect(result.code == 0)
    }

    @Test("--out redirects the eject destination")
    func ejectOutRedirectsDestination() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outPath = dir.appendingPathComponent("elsewhere/refinement-copy.md").path

        let result = run(["--eject-prompt", "refinement", "--out", outPath], in: dir)
        #expect(result.code == 0)
        #expect(result.stdout.lines == [outPath])
        #expect(FileManager.default.fileExists(atPath: outPath))
        // The default destination must not have been touched.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("refinement.md").path))
    }

    @Test("ejecting an unknown id fails (exit 1)")
    func ejectUnknownIdFails() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--eject-prompt", "not-a-real-id"], in: dir)
        #expect(result.code == 1)
        #expect(!result.stderr.lines.isEmpty)
    }

    @Test("ejecting a dictation/apps/<bundle-id> id writes an empty-body skeleton under dictation/apps/, exit 0")
    func ejectDictationAppWritesSkeleton() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--eject-prompt", "dictation/apps/com.apple.dt.Xcode"], in: dir)
        #expect(result.code == 0)

        let expectedPath = dir
            .appendingPathComponent("dictation/apps/com.apple.dt.Xcode.md").path
        #expect(result.stdout.lines == [expectedPath])
        let contents = (try? String(contentsOfFile: expectedPath, encoding: .utf8)) ?? ""
        #expect(contents.contains("prompt: dictation/apps/com.apple.dt.Xcode"))
    }

    @Test("ejecting a dictation/apps id with an invalid bundle id charset fails (exit 1)")
    func ejectDictationAppInvalidBundleIdFails() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--eject-prompt", "dictation/apps/not a bundle id!"], in: dir)
        #expect(result.code == 1)
    }

    // MARK: - --validate-prompts (§6.2)

    @Test("validating an empty directory reports nothing (exit 0)")
    func validateEmptyDirectoryIsClean() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--validate-prompts"], in: dir)
        #expect(result.code == 0)
        #expect(result.stdout.lines.isEmpty)
    }

    @Test("validating a requested id with no override file reports nothing (exit 0)")
    func validateRequestedIdWithNoFileIsClean() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--validate-prompts", "refinement"], in: dir)
        #expect(result.code == 0)
        #expect(result.stdout.lines.isEmpty)
    }

    @Test("validating an unparseable id argument is a usage error (exit 1)")
    func validateUnknownIdArgumentFails() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--validate-prompts", "not-a-real-id"], in: dir)
        #expect(result.code == 1)
    }

    @Test("a file with no frontmatter delimiters is an ERROR finding (exit 1)")
    func validateMissingFrontmatterIsError() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "この行から始まる、frontmatter の無い本文だけのファイル。"
            .write(to: dir.appendingPathComponent("refinement.md"), atomically: true, encoding: .utf8)

        let result = run(["--validate-prompts"], in: dir)
        #expect(result.code == 1)
        #expect(result.stdout.lines.contains { $0.hasPrefix("ERROR ") })
    }

    @Test("a freshly-ejected default override validates clean (exit 0)")
    func validateFreshlyEjectedOverrideIsClean() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(run(["--eject-prompt", "refinement"], in: dir).code == 0)

        let result = run(["--validate-prompts", "refinement"], in: dir)
        #expect(result.code == 0)
        #expect(result.stdout.lines.isEmpty)
    }

    @Test("a stale based_on hash is reported without being an ERROR (exit 2)")
    func validateStaleBasedOnIsWarningLevel() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = """
        ---
        prompt: refinement
        based_on: 000000000000
        reload: session-start
        placeholders:
          required: []
          optional: []
        ---

        これはユーザーが手で書いた有効な方針層の本文です。
        """
        try fixture.write(to: dir.appendingPathComponent("refinement.md"), atomically: true, encoding: .utf8)

        let result = run(["--validate-prompts"], in: dir)
        #expect(result.code == 2)
        #expect(result.stdout.lines.contains { $0.hasPrefix("STALE ") })
        #expect(!result.stdout.lines.contains { $0.hasPrefix("ERROR ") })
    }

    // MARK: - --render-prompt (§6.2)

    @Test("rendering an unknown id fails (exit 1)")
    func renderUnknownIdFails() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--render-prompt", "not-a-real-id"], in: dir)
        #expect(result.code == 1)
    }

    @Test("rendering chat with no override equals PromptSpec's default body verbatim (no contract layer)")
    func renderChatDefaultEqualsSpecDefaultBody() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--render-prompt", "chat"], in: dir)
        #expect(result.code == 0)
        #expect(result.stdout.joined == PromptSpec.spec(for: .chat).defaultBody)
    }

    @Test("rendering final-title with no override equals PromptSpec's default body verbatim (no contract layer)")
    func renderFinalTitleDefaultEqualsSpecDefaultBody() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--render-prompt", "final-title"], in: dir)
        #expect(result.code == 0)
        #expect(result.stdout.joined == PromptSpec.spec(for: .finalTitle).defaultBody)
    }

    @Test("rendering summary with no override matches SummaryPromptBuilder.systemPrompt(policyBody:) applied to the default body")
    func renderSummaryDefaultMatchesDirectBuilderCall() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--render-prompt", "summary"], in: dir)
        #expect(result.code == 0)

        let expected = SummaryPromptBuilder.systemPrompt(policyBody: PromptSpec.spec(for: .summary).defaultBody)
        #expect(result.stdout.joined == expected)
    }

    @Test("rendering a prompt with a builder (refinement) is deterministic across repeated calls with no override present")
    func renderRefinementIsDeterministic() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstRun = run(["--render-prompt", "refinement"], in: dir)
        #expect(firstRun.code == 0)
        let secondRun = run(["--render-prompt", "refinement"], in: dir)
        #expect(secondRun.code == 0)
        #expect(firstRun.stdout.joined == secondRun.stdout.joined)
        #expect(!firstRun.stdout.joined.isEmpty)
    }

    @Test("rendering an invalid override falls back to the same output as no override, warns on stderr, and exits 2")
    func renderInvalidOverrideFallsBackWithWarning() throws {
        let noOverrideDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: noOverrideDir) }
        let defaultOutput = run(["--render-prompt", "refinement"], in: noOverrideDir)
        #expect(defaultOutput.code == 0)

        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // No frontmatter delimiters at all: unambiguously invalid (§8 #3), regardless of the
        // exact validator implementation.
        try "frontmatter の無い、壊れた override ファイル。KIKIMI_RENDER_TEST_MARKER"
            .write(to: dir.appendingPathComponent("refinement.md"), atomically: true, encoding: .utf8)

        let result = run(["--render-prompt", "refinement"], in: dir)
        #expect(result.code == 2)
        #expect(!result.stderr.lines.isEmpty)

        // The invalid override must not have leaked into the rendered output, which must match
        // the no-override default exactly.
        #expect(!result.stdout.joined.contains("KIKIMI_RENDER_TEST_MARKER"))
        #expect(result.stdout.joined == defaultOutput.stdout.joined)
    }

    // MARK: - --list-prompts (§6.2)

    @Test("listing with no overrides reports every PromptID as default, exit 0")
    func listWithNoOverridesReportsAllDefault() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = run(["--list-prompts"], in: dir)
        #expect(result.code == 0)
        #expect(result.stdout.lines.count == PromptID.allCases.count)
        for line in result.stdout.lines {
            #expect(line.hasSuffix("\tdefault\t-"))
        }
        let ids = Set(result.stdout.lines.compactMap { $0.split(separator: "\t").first.map(String.init) })
        #expect(ids == Set(PromptID.allCases.map(\.rawValue)))
    }

    @Test("listing after a fresh eject reports that id as an override with current staleness")
    func listAfterEjectReportsOverrideCurrent() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(run(["--eject-prompt", "refinement"], in: dir).code == 0)

        let result = run(["--list-prompts"], in: dir)
        #expect(result.code == 0)
        #expect(result.stdout.lines.contains("refinement\toverride\tcurrent"))
    }

    @Test("listing includes dictation/apps/<bundle-id> entries after ejecting one")
    func listIncludesDictationAppEntries() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(run(["--eject-prompt", "dictation/apps/com.apple.dt.Xcode"], in: dir).code == 0)

        let result = run(["--list-prompts"], in: dir)
        #expect(result.code == 0)
        #expect(result.stdout.lines.contains("dictation/apps/com.apple.dt.Xcode\toverride\t-"))
    }
}
