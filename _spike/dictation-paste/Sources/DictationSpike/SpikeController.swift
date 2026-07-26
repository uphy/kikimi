import AppKit
import ApplicationServices
import Carbon.HIToolbox

private enum HotKey {
    static let dictate: UInt32 = 1
    static let methodBase: UInt32 = 10  // 11 / 12 / 13 select the insertion method
}

final class SpikeController: NSObject, NSApplicationDelegate {
    /// Stands in for a refined dictation result. Japanese on purpose: the IME
    /// interaction is part of what we are probing.
    private let sampleText = "次のスプリントで対応します。"

    /// Simulates the round-trip of a single-shot LLM refinement call. The gap
    /// between key-release and insertion is where focus can move away.
    private let refinementDelay: TimeInterval = {
        guard let raw = ProcessInfo.processInfo.environment["SPIKE_DELAY_MS"],
              let ms = Double(raw) else { return 0.8 }
        return ms / 1000
    }()

    private var monitor: HotKeyMonitor?
    private var statusItem: NSStatusItem?
    private var signalSource: DispatchSourceSignal?
    private var probeSource: DispatchSourceSignal?
    private var probeBaseline: (pid: pid_t, element: AXUIElement?)?
    private var method: InsertionMethod = .pasteboard
    private var pressedAt: Date?

    /// Drives one insertion without a keypress: `kill -USR1 <pid>`.
    /// Synthesized modifier+key events do not reach a Carbon hotkey, so scripted
    /// runs across many target apps need a side channel.
    private static let signalTriggerPath = "/tmp/dictation-spike.method"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.startSession()
        Log.write("=== dictation-paste spike ===")
        Log.write("refinement delay: \(Int(refinementDelay * 1000))ms (override with SPIKE_DELAY_MS)")

        installStatusItem()
        installSignalTrigger()
        awaitAccessibilityTrust { [weak self] in
            guard let self else { return }
            self.installHotKeys()
            Log.write("ready. hold ⌃⌥Space in a target app; ⌃⌥1/⌃⌥2/⌃⌥3 switch method")
            Log.write("pid \(ProcessInfo.processInfo.processIdentifier) — kill -USR1 to trigger")
            Log.write("method: \(self.method.label)")
        }
    }

    /// SIGUSR1 fires one insertion against whatever is frontmost. The method is read
    /// from `signalTriggerPath` ("1"/"2"/"3") so a script can sweep all three.
    private func installSignalTrigger() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if let raw = try? String(contentsOfFile: Self.signalTriggerPath, encoding: .utf8),
               let selected = InsertionMethod(rawValue: Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) {
                self.method = selected
            }
            Log.write("── SIGUSR1 (method: \(self.method.label))")
            self.beginInsertion()
        }
        source.resume()
        signalSource = source

        installFocusProbe()
    }

    /// SIGUSR2 reads the focused element and compares it to the previous probe.
    /// Inserts nothing. Answers the question the misfire guard depends on: does an
    /// app hand out a distinct AXUIElement per field, or one element per window?
    private func installFocusProbe() {
        signal(SIGUSR2, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        source.setEventHandler { [weak self] in self?.probeFocus() }
        source.resume()
        probeSource = source
    }

    private func probeFocus() {
        let snapshot = FocusSnapshot.capture()
        var line = "probe: \(snapshot.appName) pid=\(snapshot.pid) role=\(snapshot.role)"

        if let previous = probeBaseline {
            if previous.pid != snapshot.pid {
                line += " | pid differs (no comparison)"
            } else if let a = previous.element, let b = snapshot.element {
                line += CFEqual(a, b) ? " | element SAME as previous" : " | element DIFFERENT from previous"
            } else {
                line += " | element missing on one side"
            }
        } else {
            line += " | baseline"
        }

        line += " " + Self.identityAttributes(of: snapshot.element)
        Log.write(line)
        probeBaseline = (snapshot.pid, snapshot.element)
    }

    /// Attributes that might distinguish two fields even when the element itself is reused.
    private static func identityAttributes(of element: AXUIElement?) -> String {
        guard let element else { return "[no element]" }
        let names = [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXRoleDescriptionAttribute]
        let parts: [String] = names.compactMap { name in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                  let text = value as? String, !text.isEmpty
            else { return nil }
            return "\(name)=\(text)"
        }
        return parts.isEmpty ? "[no identity attrs]" : "[\(parts.joined(separator: " "))]"
    }

    // MARK: - Permissions

    /// Carbon hotkeys register without Accessibility, but both insertion paths
    /// (AX writes and CGEvent posts) silently no-op without it. So arm nothing
    /// until trust is granted, and poll instead of demanding a relaunch — there
    /// is no event tap here that would need re-creating.
    private func awaitAccessibilityTrust(_ onTrusted: @escaping () -> Void) {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            onTrusted()
            return
        }

        Log.write("NOT TRUSTED for Accessibility — grant it in System Settings, waiting…")
        poll(onTrusted)
    }

    private func poll(_ onTrusted: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if AXIsProcessTrusted() {
                Log.write("trust granted")
                onTrusted()
            } else {
                self.poll(onTrusted)
            }
        }
    }

    // MARK: - Wiring

    private func installHotKeys() {
        let monitor = HotKeyMonitor { [weak self] event in
            self?.handle(event)
        }
        monitor.start()
        // ⌃⌥ rather than ⌥ alone: Raycast owns ⌥Space via a CGEventTap, which sits ahead
        // of Carbon hotkeys in the dispatch order. RegisterEventHotKey still succeeds, so
        // both fired — the launcher opened *and* the text was inserted.
        let modifiers = UInt32(controlKey | optionKey)
        monitor.register(id: HotKey.dictate, keyCode: UInt32(kVK_Space), modifiers: modifiers)
        monitor.register(id: HotKey.methodBase + 1, keyCode: UInt32(kVK_ANSI_1), modifiers: modifiers)
        monitor.register(id: HotKey.methodBase + 2, keyCode: UInt32(kVK_ANSI_2), modifiers: modifiers)
        monitor.register(id: HotKey.methodBase + 3, keyCode: UInt32(kVK_ANSI_3), modifiers: modifiers)
        self.monitor = monitor
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🎤"
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    // MARK: - Gesture

    private func handle(_ event: HotKeyMonitor.Event) {
        switch event {
        case .pressed(HotKey.dictate):
            pressedAt = Date()
            Log.write("── press ⌃⌥Space")

        case .released(HotKey.dictate):
            let held = pressedAt.map { Date().timeIntervalSince($0) } ?? -1
            pressedAt = nil
            Log.write(String(format: "── release ⌃⌥Space (held %.0fms)", held * 1000))
            beginInsertion()

        case .pressed(let id) where id > HotKey.methodBase:
            if let selected = InsertionMethod(rawValue: Int(id - HotKey.methodBase)) {
                method = selected
                Log.write("method: \(selected.label)")
            }

        default:
            break
        }
    }

    private func beginInsertion() {
        let target = FocusSnapshot.capture()
        let method = self.method
        Log.write("   target: \(target.description)")

        let releasedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + refinementDelay) {
            if !target.isStillFrontmost {
                let now = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                Log.write("   ⚠︎ focus moved during delay: \(target.appName) → \(now)")
            }

            let insertStart = Date()
            let result = TextInserter.insert(self.sampleText, method: method, into: target)
            let insertMs = Date().timeIntervalSince(insertStart) * 1000
            let totalMs = Date().timeIntervalSince(releasedAt) * 1000

            Log.write(String(
                format: "   %@ → %@ (insert %.0fms, release→done %.0fms)",
                method.label, result.description, insertMs, totalMs
            ))

            // The insert call only reports that the write/keystroke was issued. Pasteboard
            // insertion in particular always claims success — the target app may ignore the
            // synthesized ⌘V entirely. Read the field back to learn what really happened.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                Log.write("   readback: \(self.readBack(target))")
            }
        }
    }

    private func readBack(_ target: FocusSnapshot) -> String {
        guard let element = target.element else { return "unverifiable (no AX element)" }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard status == .success else {
            return "unverifiable (AXValue unreadable, AXError \(status.rawValue))"
        }
        guard let text = value as? String else {
            return "unverifiable (AXValue is not a string)"
        }
        if text.contains(sampleText) {
            return "VERIFIED — sample text present"
        }
        // Electron/Monaco hands back an empty AXValue even when the editor holds text,
        // so an empty read proves nothing. Reporting it as "not inserted" was a false
        // negative: VS Code accepted both pasteboard and unicode insertions.
        if text.isEmpty {
            return "unverifiable (AXValue empty — app does not expose content via AX)"
        }
        return "NOT INSERTED — text absent"
    }
}
