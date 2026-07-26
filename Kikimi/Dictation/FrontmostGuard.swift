import ApplicationServices
import Foundation

// MARK: - AXUIElementBox

/// `Equatable` wrapper over `AXUIElement` (an opaque `CFTypeRef`, not natively `Equatable`), so
/// `FrontmostGuard.Target` can be compared with plain `==` (`docs/design/25-dictation-mode.md`
/// §8). Identity is `CFEqual`, matching the spike's SIGUSR2 probe finding: Electron apps (Slack)
/// hand out a distinct `AXUIElement` per focused field, and re-reading the same field twice yields
/// a `CFEqual`-equal element -- a stable basis for "did the focused element change" even in apps
/// where writing to that element (AX insertion) does not work.
struct AXUIElementBox: Equatable, @unchecked Sendable {
    let element: AXUIElement

    static func == (lhs: AXUIElementBox, rhs: AXUIElementBox) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

// MARK: - FrontmostGuard

/// Decides whether a delayed text insertion may still land on the app the user intended, or must
/// be aborted (`docs/design/25-dictation-mode.md` R5/§8). Pure and side-effect-free by design: it
/// takes two already-captured `Target` snapshots (at key-release time and immediately before
/// insertion) and returns a `Decision`, so it is unit-testable without touching AppKit/AX at all
/// beyond constructing the `AXUIElement` values themselves.
///
/// Both a synthesized `⌘V` and a `CGEvent` unicode direct-type are destination-less: the OS
/// delivers them to whatever holds keyboard focus *at post time*, not to a target chosen by the
/// caller. Since insertion happens after refinement (D2) or STT `finish()` (D1) -- not at the
/// instant of key-release -- the focus may have moved in between. AX element identity (`CFEqual`)
/// is the primary signal because pid alone misses focus moving between two fields inside the same
/// app (Slack's message box vs. its `⌘K` search field, both same pid); pid is only the fallback
/// when either snapshot has no focused element to compare (`kAXErrorNoValue`, or an app -- e.g.
/// Electron -- that simply doesn't expose one at that moment).
enum FrontmostGuard {
    /// One focus snapshot. `element` is `nil` when nothing was focused at capture time
    /// (`kAXErrorNoValue`) -- confirmed by the spike to mean "no focused element right now", not
    /// "this app hides its elements from AX".
    struct Target: Equatable, Sendable {
        var bundleId: String?
        var pid: pid_t
        var element: AXUIElementBox?
    }

    enum Decision: Equatable, Sendable {
        case insert
        case abortAndStash
    }

    /// - Parameters:
    ///   - captured: The target snapshotted at key-release time.
    ///   - current: The target snapshotted immediately before the actual insertion.
    static func decide(captured: Target, current: Target) -> Decision {
        guard current.pid == captured.pid else {
            return .abortAndStash
        }

        // Same process. Prefer the focused element when both sides expose one -- it catches focus
        // moving between fields inside a single app. Reading the element works even where writing
        // to it does not (Electron); only when a side reports no focused element does this degrade
        // to pid equality.
        if let capturedElement = captured.element, let currentElement = current.element {
            return capturedElement == currentElement ? .insert : .abortAndStash
        }
        return .insert
    }
}
