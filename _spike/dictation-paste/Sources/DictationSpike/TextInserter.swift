import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InsertionMethod: Int, CaseIterable {
    case axSelectedText = 1
    case pasteboard = 2
    case unicodeKeyEvents = 3

    var label: String {
        switch self {
        case .axSelectedText: return "AX kAXSelectedText"
        case .pasteboard: return "Pasteboard + ⌘V"
        case .unicodeKeyEvents: return "CGEvent unicode"
        }
    }
}

enum InsertionResult {
    case ok
    case failed(String)

    var description: String {
        switch self {
        case .ok: return "OK"
        case .failed(let reason): return "FAILED (\(reason))"
        }
    }
}

enum TextInserter {
    static func insert(_ text: String, method: InsertionMethod, into target: FocusSnapshot) -> InsertionResult {
        switch method {
        case .axSelectedText: return insertViaAX(text, target: target)
        case .pasteboard: return insertViaPasteboard(text)
        case .unicodeKeyEvents: return insertViaUnicodeEvents(text)
        }
    }

    // MARK: - 1. AX

    /// Setting kAXSelectedText on a focused element replaces the selection (or
    /// inserts at the caret when the selection is empty). Native Cocoa text
    /// views honor this; Electron/Chromium ones typically do not.
    private static func insertViaAX(_ text: String, target: FocusSnapshot) -> InsertionResult {
        guard let element = target.element else {
            return .failed("no focused AX element")
        }
        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard status == .success else {
            return .failed("AXError \(status.rawValue)")
        }
        return .ok
    }

    // MARK: - 2. Pasteboard

    /// Stashes and restores the user's clipboard around the paste. The restore is
    /// deliberately delayed: the target app reads the pasteboard asynchronously
    /// after receiving ⌘V, so restoring immediately races it.
    private static func insertViaPasteboard(_ text: String) -> InsertionResult {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return .failed("pasteboard write rejected")
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed("no CGEventSource")
        }
        // Suppress the physical modifier state (the hotkey's ⌥ may still be held)
        // so the synthesized ⌘V is not reinterpreted as ⌥⌘V.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            return .failed("CGEvent creation failed")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        return .ok
    }

    // MARK: - 3. Unicode key events

    /// Types the string as synthesized key events carrying a unicode payload.
    /// Needs no pasteboard and no AX write, but each event is capped at a small
    /// number of UTF-16 units, so long text must be chunked.
    private static func insertViaUnicodeEvents(_ text: String) -> InsertionResult {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed("no CGEventSource")
        }

        let units = Array(text.utf16)
        let chunkSize = 16

        for start in stride(from: 0, to: units.count, by: chunkSize) {
            var chunk = Array(units[start..<min(start + chunkSize, units.count)])

            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                return .failed("CGEvent creation failed at offset \(start)")
            }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
        return .ok
    }
}
