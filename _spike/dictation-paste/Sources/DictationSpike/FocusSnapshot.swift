import AppKit
import ApplicationServices

/// The insertion target, captured at key-release time rather than at insert time.
///
/// This distinction is the whole point of capturing a snapshot: refinement adds
/// ~1s of latency between "user stopped talking" and "text is ready", and the
/// user may switch apps during that window.
struct FocusSnapshot {
    let appName: String
    let bundleID: String
    let pid: pid_t
    let element: AXUIElement?
    let role: String

    static func capture() -> FocusSnapshot {
        let front = NSWorkspace.shared.frontmostApplication

        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )

        var element: AXUIElement?
        if status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            element = (focused as! AXUIElement)  // swiftlint:disable:this force_cast
        }

        return FocusSnapshot(
            appName: front?.localizedName ?? "?",
            bundleID: front?.bundleIdentifier ?? "?",
            pid: front?.processIdentifier ?? -1,
            element: element,
            role: element.flatMap { copyRole(of: $0) } ?? "<no AX element: \(status.rawValue)>"
        )
    }

    private static func copyRole(of element: AXUIElement) -> String? {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
        else { return nil }
        return role as? String
    }

    /// True when the frontmost app still matches the one captured. Lets the spike
    /// report whether a delayed insert would have landed in the wrong window.
    var isStillFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    var description: String {
        "\(appName) (\(bundleID)) role=\(role)"
    }
}
