import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog

// MARK: - DictationInsertOutcome

enum DictationInsertOutcome: Equatable, Sendable {
    /// Inserted into the still-focused target.
    case inserted
    /// The focus target changed between capture and insertion (`FrontmostGuard.Decision
    /// .abortAndStash`); the text was stashed to the pasteboard instead (logged only -- see
    /// `stashToPasteboard(_:)`'s doc comment on why no notification is posted;
    /// `docs/design/25-dictation-mode.md` R5/§8's D1 stash path).
    case abortedAndStashed
}

// MARK: - DictationInserting

/// `DictationController`'s (and `DictationOverlayPanelController`'s) seam onto `DictationInserter`,
/// so tests can substitute a recording spy instead of exercising the real `CGEvent`-synthesized
/// `⌘V`/pasteboard-write insertion path against whatever app is actually frontmost during a test
/// run. Mirrors every other `.shared`-style dependency's DI pattern on this type (see
/// `DictationController`'s `historyStore`/`refiner`).
@MainActor
protocol DictationInserting: AnyObject {
    func captureTarget() -> FrontmostGuard.Target
    func insert(text: String, capturedTarget: FrontmostGuard.Target, method: DictationInsertMethod) -> DictationInsertOutcome
    func performInsert(_ text: String, method: DictationInsertMethod)
}

// MARK: - DictationInserter

/// Captures the insertion target at key-release time, re-verifies it immediately before actually
/// inserting, and performs the insertion (or aborts and stashes) accordingly
/// (`docs/design/25-dictation-mode.md` R5/R6/§8).
///
/// `@MainActor`: `NSWorkspace`/`AXUIElementCreateSystemWide`/`NSPasteboard`/`CGEvent` posting are
/// all main-thread-conventional AppKit/Carbon APIs, and `DictationController` (the sole caller)
/// already runs on the main actor.
@MainActor
final class DictationInserter: DictationInserting {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationInserter")

    /// Snapshots the current keyboard focus as a `FrontmostGuard.Target`. Called both at
    /// key-release time (the "captured" snapshot) and immediately before insertion (the "current"
    /// snapshot) -- see `insert(text:capturedTarget:method:)`.
    ///
    /// `element` is `nil` when nothing is focused right now (`kAXErrorNoValue`, confirmed by the
    /// spike to mean exactly that, not "this app hides its elements from AX").
    func captureTarget() -> FrontmostGuard.Target {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return FrontmostGuard.Target(
            bundleId: frontmost?.bundleIdentifier,
            pid: frontmost?.processIdentifier ?? -1,
            element: Self.copyFocusedElement().map(AXUIElementBox.init)
        )
    }

    /// Re-captures the current focus target, runs `FrontmostGuard.decide`, and either performs the
    /// insertion or stashes `text` to the pasteboard (D1's abort path; D2 will route this to
    /// `DictationOverlayPanel` instead, per the design doc).
    func insert(text: String, capturedTarget: FrontmostGuard.Target, method: DictationInsertMethod) -> DictationInsertOutcome {
        guard !text.isEmpty else {
            return .inserted
        }

        let currentTarget = captureTarget()
        switch FrontmostGuard.decide(captured: capturedTarget, current: currentTarget) {
        case .insert:
            performInsert(text, method: method)
            return .inserted
        case .abortAndStash:
            logger.warning("dictation insert aborted: focus target changed since key-release; stashing to the pasteboard")
            stashToPasteboard(text)
            return .abortedAndStashed
        }
    }

    // MARK: - Focus capture

    private static func copyFocusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return (focused as! AXUIElement)
    }

    // MARK: - Insertion (R6)

    /// Inserts `text` into whatever holds keyboard focus **right now**, with no `FrontmostGuard`
    /// check at all. Exposed (not `private`) for `DictationOverlayPanel`'s `[挿入]` button (D2,
    /// R5/§8): "ユーザーが `[挿入]` で『今の』frontmost へ入れ直せる（再度の検証は挟まない —
    /// ユーザーが明示的に押した瞬間の frontmost を意図とみなす）". `insert(text:capturedTarget:method:)`
    /// is the guarded entry point every other caller should use instead.
    func performInsert(_ text: String, method: DictationInsertMethod) {
        switch method {
        case .pasteboard:
            insertViaPasteboard(text)
        case .unicode:
            insertViaUnicode(text)
        }
    }

    /// The nspasteboard.org convention (honored by Raycast, Maccy, etc.) marking a pasteboard
    /// write that clipboard-history managers must not record. Attached to the transient dictation
    /// write in `insertViaPasteboard` only -- `stashToPasteboard` and the overlay's copy button
    /// deliberately leave the text visible to history, since there the pasteboard IS the delivery.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Stashes the user's current pasteboard contents, writes `text`, posts a synthesized `⌘V`,
    /// then restores the pasteboard after a delay long enough for the target app to have read it
    /// (the spike's finding: restoring immediately races the target app's asynchronous paste
    /// handling).
    private func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString("", forType: Self.concealedType)
        guard pasteboard.setString(text, forType: .string) else {
            logger.error("dictation insert failed: pasteboard write rejected")
            return
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            logger.error("dictation insert failed: could not create CGEventSource")
            return
        }
        // Suppresses the physical modifier state (the hotkey's own modifiers may still be
        // transitioning to "up") so the synthesized ⌘V is not reinterpreted with a stray modifier
        // still attached (spike finding).
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            logger.error("dictation insert failed: could not create CGEvent for ⌘V")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pasteboard.clearContents()
            if let saved {
                pasteboard.setString(saved, forType: .string)
            }
        }
    }

    /// Types `text` as synthesized key events carrying a unicode payload -- no pasteboard, no AX
    /// write. Each `CGEvent` can only carry a small number of UTF-16 units, so long text is sent in
    /// chunks (the spike confirmed 16-unit chunks land correctly across native/Chromium/Electron/
    /// terminal targets).
    private func insertViaUnicode(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            logger.error("dictation insert failed: could not create CGEventSource")
            return
        }

        let units = Array(text.utf16)
        let chunkSize = 16
        for start in stride(from: 0, to: units.count, by: chunkSize) {
            var chunk = Array(units[start..<min(start + chunkSize, units.count)])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                logger.error("dictation insert failed: could not create CGEvent at offset \(start, privacy: .public)")
                return
            }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    // MARK: - Abort/stash (R5, D1 scope)

    /// D1's abort destination: overwrite the pasteboard with the dictated text (never silently
    /// dropping it, per R5's "テキストは絶対に失わない"). No system notification is posted --
    /// dropped after D1 shipped because this path is hard to trigger on demand for hand
    /// verification (it requires timing a focus switch during the STT `finish()` window), so its
    /// delivery was never actually confirmed; the caller already logs the abort via `.warning`.
    /// D2+ will replace this with `DictationOverlayPanel` once the higher misfire probability from
    /// refinement's ~1s round trip justifies that panel's implementation cost.
    private func stashToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
