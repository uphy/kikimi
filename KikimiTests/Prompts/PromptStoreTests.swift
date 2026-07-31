import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `PromptStore` (`docs/design/42-prompt-overrides.md` §4.1/§5.1/§9.1): the
/// none/active/invalid resolution states, `writeOverride`/`removeOverride`'s round trip (including the
/// empty-body branch), `dictationAppBundleIDs()` enumeration, `refreshIfStale()`'s synchronous safety
/// net, and the 2-layer watch (directory + per-file) picking up both in-place and atomic-write edits.
/// Every test roots a fresh `PromptStore` at its own temporary directory, so nothing here ever touches
/// the real `~/.config/kikimi/prompts`.
@Suite("PromptStore")
@MainActor
struct PromptStoreTests {
    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a raw override file straight to disk, bypassing `PromptStore` entirely -- used to set
    /// up scenarios `writeOverride` itself would refuse to produce (an empty body for a non-dictation
    /// id, malformed frontmatter), and to simulate edits `PromptStore`'s own watch is expected to
    /// notice.
    private func writeRawFile(_ text: String, name: String, in directory: URL, atomically: Bool = true) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        if atomically {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try Data(text.utf8).write(to: url, options: [])
        }
    }

    // MARK: - none / active / invalid resolution (§5.1's state diagram)

    @Test("no override file resolves to .none, and policyBody falls back to the built-in default")
    func noOverrideResolvesToNone() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PromptStore(directory: dir)
        #expect(store.overrideState(for: .builtin(.refinement)) == .none)
        #expect(store.policyBody(for: .builtin(.refinement)) == PromptSpec.spec(for: .refinement).defaultBody)
    }

    @Test("a valid override file resolves to .active, and policyBody returns its trimmed body")
    func validOverrideResolvesToActive() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spec = PromptSpec.spec(for: .chat)
        let text = PromptFile.render(id: "chat", spec: spec, body: "  カスタム方針  ")
        try writeRawFile(text, name: "chat.md", in: dir)

        let store = PromptStore(directory: dir)
        guard case .active(let body, let basedOn) = store.overrideState(for: .builtin(.chat)) else {
            Issue.record("expected .active, got \(store.overrideState(for: .builtin(.chat)))")
            return
        }
        #expect(body == "カスタム方針")
        #expect(basedOn == PromptSpec.defaultBodyHash(.chat))
        #expect(store.policyBody(for: .builtin(.chat)) == "カスタム方針")
    }

    @Test("an override file with no frontmatter resolves to .invalid, and policyBody falls back to the default")
    func missingFrontmatterResolvesToInvalid() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeRawFile("no frontmatter here, just a body.", name: "chat.md", in: dir)

        let store = PromptStore(directory: dir)
        #expect(store.overrideState(for: .builtin(.chat)) == .invalid(.frontmatterMissing))
        #expect(store.policyBody(for: .builtin(.chat)) == PromptSpec.spec(for: .chat).defaultBody)
    }

    @Test("an override file declaring a mismatched `prompt:` id resolves to .invalid")
    func mismatchedPromptFieldResolvesToInvalid() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Rendered for `refinement`, but placed at `chat.md` -- a copy/paste or rename accident (§8 #4).
        let text = PromptFile.render(id: "refinement", spec: PromptSpec.spec(for: .refinement), body: "本文")
        try writeRawFile(text, name: "chat.md", in: dir)

        let store = PromptStore(directory: dir)
        #expect(store.overrideState(for: .builtin(.chat)) == .invalid(.promptFieldMismatch(declared: "refinement", expected: "chat")))
    }

    @Test("bytes that don't decode as UTF-8 resolve to .invalid(.fileNotUTF8)")
    func nonUTF8FileResolvesToInvalid() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 0xFF 0xFE is not valid UTF-8 on its own.
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: dir.appendingPathComponent("chat.md"))

        let store = PromptStore(directory: dir)
        #expect(store.overrideState(for: .builtin(.chat)) == .invalid(.fileNotUTF8))
        #expect(store.policyBody(for: .builtin(.chat)) == PromptSpec.spec(for: .chat).defaultBody)
    }

    // MARK: - 空本文の分岐 (§3.2/§8 #6)

    @Test("an empty body resolves to .invalid(.emptyBody) for a non-dictation id")
    func emptyBodyForNonDictationIdIsInvalid() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = PromptFile.render(id: "refinement", spec: PromptSpec.spec(for: .refinement), body: "   ")
        try writeRawFile(text, name: "refinement.md", in: dir)

        let store = PromptStore(directory: dir)
        #expect(store.overrideState(for: .builtin(.refinement)) == .invalid(.emptyBody))
    }

    @Test("an empty body resolves to a valid .active(body: \"\") for `dictation`, R17's escape hatch")
    func emptyBodyForDictationIsActive() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = PromptFile.render(id: "dictation", spec: PromptSpec.spec(for: .dictation), body: "")
        try writeRawFile(text, name: "dictation.md", in: dir)

        let store = PromptStore(directory: dir)
        #expect(store.overrideState(for: .builtin(.dictation)) == .active(body: "", basedOn: PromptSpec.defaultBodyHash(.dictation)))
        #expect(store.policyBody(for: .builtin(.dictation)) == "")
    }

    @Test("writeOverride accepts an empty body for `dictation`")
    func writeOverrideAllowsEmptyBodyForDictation() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)

        try store.writeOverride(.builtin(.dictation), body: "")
        #expect(store.overrideState(for: .builtin(.dictation)) == .active(body: "", basedOn: PromptSpec.defaultBodyHash(.dictation)))
    }

    @Test("writeOverride accepts an empty body for a dictation per-app addition")
    func writeOverrideAllowsEmptyBodyForDictationApp() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)

        try store.writeOverride(.dictationApp(bundleID: "com.example.App"), body: "")
        #expect(store.overrideState(for: .dictationApp(bundleID: "com.example.App")) != .none)
        #expect(store.policyBody(for: .dictationApp(bundleID: "com.example.App")) == "")
    }

    @Test("writeOverride throws PromptFileError.emptyBody for a non-dictation id's empty body, and writes nothing")
    func writeOverrideThrowsForEmptyBodyOnNonDictationId() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)

        #expect(throws: PromptFileError.emptyBody) {
            try store.writeOverride(.builtin(.chat), body: "   ")
        }
        #expect(store.overrideState(for: .builtin(.chat)) == .none)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("chat.md").path))
    }

    // MARK: - write/remove 往復

    @Test("writeOverride writes a frontmatter'd file and rescans synchronously, so policyBody reflects it immediately")
    func writeOverrideRoundTrips() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)

        try store.writeOverride(.builtin(.summary), body: "  新しい方針  ")

        let onDisk = try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(onDisk.contains("prompt: summary"))
        #expect(onDisk.contains("新しい方針"))
        #expect(store.policyBody(for: .builtin(.summary)) == "新しい方針")
    }

    @Test("removeOverride deletes the file and rescans synchronously, restoring the built-in default")
    func removeOverrideRoundTrips() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)
        try store.writeOverride(.builtin(.summary), body: "方針")
        #expect(store.overrideState(for: .builtin(.summary)) != .none)

        try store.removeOverride(.builtin(.summary))

        #expect(store.overrideState(for: .builtin(.summary)) == .none)
        #expect(store.policyBody(for: .builtin(.summary)) == PromptSpec.spec(for: .summary).defaultBody)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path))
    }

    @Test("removeOverride is a no-op, not a throw, when no override file exists")
    func removeOverrideNoOpWhenMissing() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)

        try store.removeOverride(.builtin(.summary))
        #expect(store.overrideState(for: .builtin(.summary)) == .none)
    }

    @Test("writeOverride yields the changed PromptRef on the `changes` stream")
    func writeOverrideYieldsOnChangesStream() async throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)

        var iterator = store.changes.makeAsyncIterator()
        try store.writeOverride(.builtin(.summary), body: "本文")

        let changed = await iterator.next()
        #expect(changed == .builtin(.summary))
    }

    // MARK: - bundle id 列挙

    @Test("dictationAppBundleIDs() lists registered per-app override files, sorted, ignoring invalid names")
    func dictationAppBundleIDsEnumeratesValidFilesOnly() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)

        try store.writeOverride(.dictationApp(bundleID: "com.zzz.App"), body: "z")
        try store.writeOverride(.dictationApp(bundleID: "com.aaa.App"), body: "a")

        // An invalid bundle-id-shaped file name should be ignored, not surfaced (§3.1).
        try writeRawFile("stray file", name: "bad id!.md", in: dir.appendingPathComponent("dictation/apps", isDirectory: true))
        store.refreshIfStale()

        #expect(store.dictationAppBundleIDs() == ["com.aaa.App", "com.zzz.App"])
    }

    @Test("removing a dictation-app override drops its bundle id from dictationAppBundleIDs()")
    func removingDictationAppOverrideDropsBundleID() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)
        try store.writeOverride(.dictationApp(bundleID: "com.example.App"), body: "本文")
        #expect(store.dictationAppBundleIDs() == ["com.example.App"])

        try store.removeOverride(.dictationApp(bundleID: "com.example.App"))

        #expect(store.dictationAppBundleIDs().isEmpty)
    }

    // MARK: - refreshIfStale()

    @Test("refreshIfStale() synchronously re-scans when a file changed on disk since the last scan")
    func refreshIfStaleDetectsDriftedFingerprint() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)
        #expect(store.overrideState(for: .builtin(.summary)) == .none)

        // Write directly to disk, bypassing `PromptStore` entirely -- simulates a watch event this
        // process could plausibly miss (§5.1's failure mode #12: a coalesced kqueue notification).
        let text = PromptFile.render(id: "summary", spec: PromptSpec.spec(for: .summary), body: "直接書き込み")
        try writeRawFile(text, name: "summary.md", in: dir)

        // No `waitUntil`: unlike the debounced watch path, refreshIfStale() rescans synchronously,
        // so this must already reflect the new file with zero wait.
        store.refreshIfStale()
        #expect(store.policyBody(for: .builtin(.summary)) == "直接書き込み")
    }

    @Test("refreshIfStale() is idempotent and harmless when nothing on disk has changed")
    func refreshIfStaleNoOpWhenNothingChanged() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)
        try store.writeOverride(.builtin(.summary), body: "本文")

        store.refreshIfStale()
        store.refreshIfStale()

        #expect(store.policyBody(for: .builtin(.summary)) == "本文")
    }

    // MARK: - watch による再読込: in-place と atomic write の両方 (§5.1's 2-layer scheme)

    @Test("a directory watcher picks up a brand-new override file created directly on disk (atomic write)")
    func newOverrideFileCreatedExternallyIsPickedUpByWatch() async throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)
        #expect(store.overrideState(for: .builtin(.summary)) == .none)

        let text = PromptFile.render(id: "summary", spec: PromptSpec.spec(for: .summary), body: "新規override")
        try writeRawFile(text, name: "summary.md", in: dir)

        try await waitUntil(timeout: .seconds(10), "the new file to be picked up by the watch") {
            store.policyBody(for: .builtin(.summary)) == "新規override"
        }
    }

    @Test("a per-file watcher picks up an in-place overwrite (truncate+write, no rename)")
    func inPlaceOverwriteIsPickedUpByWatch() async throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)
        try store.writeOverride(.builtin(.chat), body: "初期本文")
        #expect(store.policyBody(for: .builtin(.chat)) == "初期本文")

        let text = PromptFile.render(id: "chat", spec: PromptSpec.spec(for: .chat), body: "書き換え後の本文")
        try writeRawFile(text, name: "chat.md", in: dir, atomically: false)

        try await waitUntil(timeout: .seconds(10), "the in-place overwrite to be picked up by the watch") {
            store.policyBody(for: .builtin(.chat)) == "書き換え後の本文"
        }
    }

    @Test("a per-file watcher's fd survives an atomic-write replacement of an existing override")
    func atomicWriteReplacementIsPickedUpByWatch() async throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)
        try store.writeOverride(.builtin(.chat), body: "初期本文")

        let text = PromptFile.render(id: "chat", spec: PromptSpec.spec(for: .chat), body: "atomic書き換え後")
        try writeRawFile(text, name: "chat.md", in: dir, atomically: true)

        try await waitUntil(timeout: .seconds(10), "the atomic-write replacement to be picked up by the watch") {
            store.policyBody(for: .builtin(.chat)) == "atomic書き換え後"
        }
    }

    @Test("the watch picks up an override file being deleted externally, restoring the built-in default")
    func overrideFileDeletedExternallyIsPickedUpByWatch() async throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStore(directory: dir)
        try store.writeOverride(.builtin(.summary), body: "本文")

        try FileManager.default.removeItem(at: dir.appendingPathComponent("summary.md"))

        try await waitUntil(timeout: .seconds(10), "the deletion to be picked up by the watch") {
            store.overrideState(for: .builtin(.summary)) == .none
        }
    }
}
