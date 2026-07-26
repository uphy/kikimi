import ApplicationServices
import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `FrontmostGuard.decide` (`docs/design/25-dictation-mode.md` §8/§11).
///
/// `AXUIElement` is an opaque `CFTypeRef` with no test-friendly constructor, so these tests use
/// `AXUIElementCreateApplication(pid:)` -- confirmed by the spike (README §F) to return a
/// `CFEqual`-stable element per pid: calling it twice with the same pid yields elements that
/// compare equal, and different pids yield elements that compare unequal. That is exactly the
/// identity property `decide` depends on, and constructing the element itself needs no
/// Accessibility permission (only *reading* its attributes does).
@Suite("FrontmostGuard")
struct FrontmostGuardTests {
    private static let pidA: pid_t = 100
    private static let pidB: pid_t = 200

    private func element(forPid pid: pid_t) -> AXUIElementBox {
        AXUIElementBox(element: AXUIElementCreateApplication(pid))
    }

    @Test("different pid aborts and stashes, regardless of elements")
    func differentPidAborts() {
        let captured = FrontmostGuard.Target(bundleId: "com.example.a", pid: Self.pidA, element: nil)
        let current = FrontmostGuard.Target(bundleId: "com.example.b", pid: Self.pidB, element: nil)
        #expect(FrontmostGuard.decide(captured: captured, current: current) == .abortAndStash)
    }

    @Test("same pid, same element (both present) inserts")
    func samePidSameElementInserts() {
        let element = element(forPid: Self.pidA)
        let captured = FrontmostGuard.Target(bundleId: "com.example.a", pid: Self.pidA, element: element)
        let current = FrontmostGuard.Target(bundleId: "com.example.a", pid: Self.pidA, element: element)
        #expect(FrontmostGuard.decide(captured: captured, current: current) == .insert)
    }

    @Test("same pid, different element (both present) aborts and stashes -- focus moved within the same app")
    func samePidDifferentElementAborts() {
        let captured = FrontmostGuard.Target(bundleId: "com.example.a", pid: Self.pidA, element: element(forPid: Self.pidA))
        let current = FrontmostGuard.Target(bundleId: "com.example.a", pid: Self.pidA, element: element(forPid: Self.pidB))
        #expect(FrontmostGuard.decide(captured: captured, current: current) == .abortAndStash)
    }

    @Test("same pid, captured element nil (kAXErrorNoValue at capture time) degrades to pid-only and inserts")
    func nilCapturedElementDegradesToPidOnly() {
        let captured = FrontmostGuard.Target(bundleId: "com.example.a", pid: Self.pidA, element: nil)
        let current = FrontmostGuard.Target(bundleId: "com.example.a", pid: Self.pidA, element: element(forPid: Self.pidA))
        #expect(FrontmostGuard.decide(captured: captured, current: current) == .insert)
    }

    @Test("same pid, current element nil (e.g. Electron not exposing one) degrades to pid-only and inserts")
    func nilCurrentElementDegradesToPidOnly() {
        let captured = FrontmostGuard.Target(bundleId: "com.example.a", pid: Self.pidA, element: element(forPid: Self.pidA))
        let current = FrontmostGuard.Target(bundleId: "com.example.a", pid: Self.pidA, element: nil)
        #expect(FrontmostGuard.decide(captured: captured, current: current) == .insert)
    }

    @Test("same pid, both elements nil degrades to pid-only and inserts")
    func bothElementsNilDegradesToPidOnly() {
        let captured = FrontmostGuard.Target(bundleId: "com.example.a", pid: Self.pidA, element: nil)
        let current = FrontmostGuard.Target(bundleId: "com.example.a", pid: Self.pidA, element: nil)
        #expect(FrontmostGuard.decide(captured: captured, current: current) == .insert)
    }
}
