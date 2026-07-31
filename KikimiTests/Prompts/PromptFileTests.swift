import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `PromptFile` (`docs/design/42-prompt-overrides.md` §3.2/§4.1/§9.1):
/// parse/render round trip, the four `PromptFileError` failure modes it names (§8 #3–#6), the
/// 32KB clamp, and the eject output's structural shape.
@Suite("PromptFile")
struct PromptFileTests {
    /// Starts from the real `PromptSpec.spec(for: id)` (so `defaultBody` -- and therefore
    /// `PromptSpec.defaultBodyHash(id)`, which `PromptFile.render` uses for `based_on` -- always
    /// stays truthful) and overrides only the fields a given test needs to vary.
    private func makeSpec(
        id: PromptID,
        reload: PromptReload? = nil,
        requiredPlaceholders: [String]? = nil,
        optionalPlaceholders: [String]? = nil,
        ejectComments: [String]? = nil
    ) -> PromptSpec {
        var spec = PromptSpec.spec(for: id)
        if let reload { spec.reload = reload }
        if let requiredPlaceholders { spec.requiredPlaceholders = requiredPlaceholders }
        if let optionalPlaceholders { spec.optionalPlaceholders = optionalPlaceholders }
        if let ejectComments { spec.ejectComments = ejectComments }
        return spec
    }

    // MARK: - parse/render round trip

    @Test("render then parse round-trips the body unchanged")
    func roundTripPreservesBody() throws {
        let spec = makeSpec(id: .simpleWatcher, ejectComments: ["備考コメント"])
        let body = "あなたは会議のリアルタイム書き起こしを観察するアシスタントです。\n{{viewpoint}} を使ってください。"

        let text = PromptFile.render(id: "simple-watcher", spec: spec, body: body)
        let result = PromptFile.parse(text: text, expectedID: "simple-watcher", spec: spec)

        let parsed = try result.get()
        #expect(parsed.body == body)
        #expect(parsed.wasClamped == false)
        #expect(parsed.basedOn == PromptSpec.defaultBodyHash(.simpleWatcher))
    }

    @Test("render trims the body before writing, and parse trims again on read-back")
    func roundTripTrimsWhitespace() throws {
        let spec = makeSpec(id: .chat)
        let text = PromptFile.render(id: "chat", spec: spec, body: "\n\n  本文  \n\n")
        let result = PromptFile.parse(text: text, expectedID: "chat", spec: spec)

        #expect(try result.get().body == "本文")
    }

    // MARK: - §8 #3: frontmatter missing / invalid YAML / not a mapping

    @Test("a file with no opening \"---\" fails with frontmatterMissing")
    func noOpeningDelimiterFails() {
        let result = PromptFile.parse(text: "prompt: chat\n---\n本文", expectedID: "chat", spec: nil)
        #expect(result == .failure(.frontmatterMissing))
    }

    @Test("a file with no closing \"---\" fails with frontmatterMissing")
    func noClosingDelimiterFails() {
        let result = PromptFile.parse(text: "---\nprompt: chat\n本文", expectedID: "chat", spec: nil)
        #expect(result == .failure(.frontmatterMissing))
    }

    @Test("malformed YAML in the frontmatter fails with frontmatterInvalidYAML")
    func invalidYAMLFails() {
        let text = """
        ---
        prompt: chat
        based_on: [unclosed
        ---

        本文
        """
        guard case .failure(.frontmatterInvalidYAML) = PromptFile.parse(text: text, expectedID: "chat", spec: nil) else {
            Issue.record("expected .frontmatterInvalidYAML")
            return
        }
    }

    @Test("frontmatter that is not a YAML mapping fails with frontmatterNotMapping")
    func nonMappingFrontmatterFails() {
        let text = """
        ---
        just a scalar string
        ---

        本文
        """
        #expect(PromptFile.parse(text: text, expectedID: "chat", spec: nil) == .failure(.frontmatterNotMapping))
    }

    @Test("empty frontmatter fails with frontmatterNotMapping")
    func emptyFrontmatterFails() {
        let text = "---\n---\n\n本文"
        #expect(PromptFile.parse(text: text, expectedID: "chat", spec: nil) == .failure(.frontmatterNotMapping))
    }

    // MARK: - §8 #4: prompt field missing / mismatched

    @Test("frontmatter with no \"prompt\" field fails with promptFieldMissing")
    func missingPromptFieldFails() {
        let text = "---\nbased_on: abc\n---\n\n本文"
        #expect(PromptFile.parse(text: text, expectedID: "chat", spec: nil) == .failure(.promptFieldMissing))
    }

    @Test("frontmatter \"prompt\" that disagrees with the path-derived id fails with promptFieldMismatch")
    func mismatchedPromptFieldFails() {
        let text = "---\nprompt: summary\n---\n\n本文"
        let result = PromptFile.parse(text: text, expectedID: "chat", spec: nil)
        #expect(result == .failure(.promptFieldMismatch(declared: "summary", expected: "chat")))
    }

    // MARK: - §8 #5: required placeholder missing

    @Test("a required placeholder missing from the body fails with requiredPlaceholderMissing")
    func missingRequiredPlaceholderFails() {
        let spec = makeSpec(id: .simpleWatcher)
        let text = "---\nprompt: simple-watcher\n---\n\n観点に関する固定の説明文のみ"
        let result = PromptFile.parse(text: text, expectedID: "simple-watcher", spec: spec)
        #expect(result == .failure(.requiredPlaceholderMissing(["{{viewpoint}}"])))
    }

    @Test("a body containing every required placeholder succeeds")
    func presentRequiredPlaceholderSucceeds() throws {
        let spec = makeSpec(id: .simpleWatcher)
        let text = "---\nprompt: simple-watcher\n---\n\n【観点】\n{{viewpoint}}"
        let parsed = try PromptFile.parse(text: text, expectedID: "simple-watcher", spec: spec).get()
        #expect(parsed.body.contains("{{viewpoint}}"))
    }

    @Test("no spec (nil) skips the required-placeholder check")
    func nilSpecSkipsPlaceholderCheck() throws {
        let text = "---\nprompt: simple-watcher\n---\n\nplaceholderを含まない本文"
        let parsed = try PromptFile.parse(text: text, expectedID: "simple-watcher", spec: nil).get()
        #expect(parsed.body == "placeholderを含まない本文")
    }

    // MARK: - §8 #6: empty body

    @Test("an empty body fails with emptyBody for a non-dictation id")
    func emptyBodyFailsForOrdinaryID() {
        let text = "---\nprompt: chat\n---\n\n   \n"
        #expect(PromptFile.parse(text: text, expectedID: "chat", spec: nil) == .failure(.emptyBody))
    }

    @Test("an empty body is a valid active override for \"dictation\"")
    func emptyBodyValidForDictation() throws {
        let text = "---\nprompt: dictation\n---\n\n   \n"
        let parsed = try PromptFile.parse(text: text, expectedID: "dictation", spec: nil).get()
        #expect(parsed.body.isEmpty)
    }

    @Test("an empty body is a valid active override for a per-app dictation id")
    func emptyBodyValidForDictationApp() throws {
        let text = "---\nprompt: dictation/apps/com.microsoft.VSCode\n---\n\n"
        let result = PromptFile.parse(text: text, expectedID: "dictation/apps/com.microsoft.VSCode", spec: nil)
        #expect(try result.get().body.isEmpty)
    }

    // MARK: - based_on missing (warning, not invalid)

    @Test("a missing \"based_on\" field parses successfully with basedOn == nil")
    func missingBasedOnIsNotFatal() throws {
        let text = "---\nprompt: chat\n---\n\n本文"
        let parsed = try PromptFile.parse(text: text, expectedID: "chat", spec: nil).get()
        #expect(parsed.basedOn == nil)
    }

    // MARK: - 32KB clamp

    @Test("a body over 32KB UTF-8 bytes is clamped, not rejected")
    func oversizedBodyIsClamped() throws {
        let oversized = String(repeating: "a", count: PromptFile.maxBodyBytes + 1_000)
        let text = "---\nprompt: chat\n---\n\n\(oversized)"
        let parsed = try PromptFile.parse(text: text, expectedID: "chat", spec: nil).get()

        #expect(parsed.wasClamped == true)
        #expect(parsed.body.utf8.count == PromptFile.maxBodyBytes)
    }

    @Test("a body within 32KB UTF-8 bytes is not clamped")
    func undersizedBodyIsNotClamped() throws {
        let text = "---\nprompt: chat\n---\n\n短い本文"
        let parsed = try PromptFile.parse(text: text, expectedID: "chat", spec: nil).get()
        #expect(parsed.wasClamped == false)
    }

    @Test("a required placeholder that only appears beyond the 32KB clamp boundary fails, not silently clamps away")
    func requiredPlaceholderBeyondClampBoundaryFails() {
        let spec = makeSpec(id: .simpleWatcher, requiredPlaceholders: ["{{viewpoint}}"])
        let padding = String(repeating: "a", count: PromptFile.maxBodyBytes)
        let text = "---\nprompt: simple-watcher\n---\n\n\(padding){{viewpoint}}"

        let result = PromptFile.parse(text: text, expectedID: "simple-watcher", spec: spec)
        #expect(result == .failure(.requiredPlaceholderMissing(["{{viewpoint}}"])))
    }

    // MARK: - render output shape

    @Test("render produces frontmatter delimiters, all documented fields, and the body verbatim")
    func renderOutputShape() throws {
        let spec = makeSpec(
            id: .simpleWatcher,
            ejectComments: ["注意: 1行目の注意コメント。\n2行目に続く。"]
        )
        let text = PromptFile.render(id: "simple-watcher", spec: spec, body: "本文です。\n{{viewpoint}}")

        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "---")
        #expect(text.components(separatedBy: "---").count - 1 == 2)
        #expect(text.contains("prompt: simple-watcher"))
        #expect(text.contains("based_on: \(PromptSpec.defaultBodyHash(.simpleWatcher))"))
        #expect(text.contains("reload: session-start"))
        #expect(text.contains("placeholders:"))
        #expect(text.contains("  required: [\"{{viewpoint}}\"]"))
        #expect(text.contains("  optional: []"))
        #expect(text.contains("# 注意: 1行目の注意コメント。"))
        #expect(text.contains("# 2行目に続く。"))
        #expect(text.hasSuffix("本文です。\n{{viewpoint}}\n"))
    }

    @Test("render's based_on always reflects the current default, regardless of the written body")
    func renderBasedOnReflectsCurrentDefault() throws {
        let spec = makeSpec(id: .chat)
        let expectedHash = PromptSpec.defaultBodyHash(.chat)

        let textA = PromptFile.render(id: "chat", spec: spec, body: "ユーザーがカスタマイズした本文A")
        let textB = PromptFile.render(id: "chat", spec: spec, body: "まったく別の本文B")

        #expect(textA.contains("based_on: \(expectedHash)"))
        #expect(textB.contains("based_on: \(expectedHash)"))
    }

    @Test("renderDictationApp emits no based_on line and round-trips through parse")
    func renderDictationAppOmitsBasedOn() throws {
        let text = PromptFile.renderDictationApp(
            bundleID: "com.example.App",
            comment: "コメント行",
            body: "  絵文字は使わない  "
        )

        #expect(!text.contains("based_on"))
        #expect(text.contains("prompt: dictation/apps/com.example.App"))
        #expect(text.contains("# コメント行"))

        let parsed = try PromptFile.parse(text: text, expectedID: "dictation/apps/com.example.App", spec: nil).get()
        #expect(parsed.body == "絵文字は使わない")
        #expect(parsed.basedOn == nil)
    }
}
