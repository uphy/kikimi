import Foundation
import Testing

@testable import Kikimi

/// Scripted `ChromeTabInspecting`. A query either answers immediately from `results`, or (when `hold`
/// is set) suspends until `release(_:)`.
final class FakeTabInspector: ChromeTabInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ChromeTabInspectionResult] = []
    private var held: [CheckedContinuation<ChromeTabInspectionResult, Never>] = []
    private var _hold = false
    private var _permitted: Bool?
    private var _inspectCount = 0
    private var _permissionChecks = 0

    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }

    var permitted: Bool? {
        get { lock.withLock { _permitted } }
        set { lock.withLock { _permitted = newValue } }
    }

    var inspectCount: Int { lock.withLock { _inspectCount } }
    var permissionChecks: Int { lock.withLock { _permissionChecks } }
    var heldCount: Int { lock.withLock { held.count } }

    func enqueue(_ result: ChromeTabInspectionResult) { lock.withLock { results.append(result) } }

    func release(_ result: ChromeTabInspectionResult) {
        let continuation = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        continuation?.resume(returning: result)
    }

    func inspect(mode: ChromeTabInspectionMode) async -> ChromeTabInspectionResult {
        let shouldHold = lock.withLock { () -> Bool in
            _inspectCount += 1
            return _hold
        }
        if shouldHold {
            return await withCheckedContinuation { continuation in
                lock.withLock { held.append(continuation) }
            }
        }
        return lock.withLock { results.isEmpty ? .tabs([]) : results.removeFirst() }
    }

    func automationPermitted() -> Bool? {
        lock.withLock {
            _permissionChecks += 1
            return _permitted
        }
    }
}

/// I/O side of the presence detector (`docs/design/50-meet-auto-record.md` section 2.3), driven by a
/// fake audio source, a fake tab inspector and an injected clock.
@MainActor
@Suite("MeetPresenceMonitor")
struct MeetPresenceMonitorTests {
    private let source = FakeChromeAudioSource()
    private let inspector = FakeTabInspector()
    private let clock = Clock()
    private let meetTab = MeetTab(code: "abc-defg-hij", title: "Weekly", isActive: true)
    private let inOut = ChromeAudioActivity(input: true, output: true)

    @MainActor
    final class Clock {
        var now = Date(timeIntervalSince1970: 3_000_000)
    }

    private final class EventLog {
        var events: [MeetPresenceDetector.Event] = []
    }

    private func makeMonitor(log: EventLog) -> MeetPresenceMonitor {
        let clock = clock
        let monitor = MeetPresenceMonitor(
            audioMonitor: source, inspector: inspector, detector: MeetPresenceDetector(),
            now: { MainActor.assumeIsolated { clock.now } }
        )
        monitor.onEvent = { log.events.append($0) }
        return monitor
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test("start and stop drive the audio source and are idempotent")
    func startStop() {
        let monitor = makeMonitor(log: EventLog())
        monitor.start()
        monitor.start()
        #expect(source.startCount == 1)
        #expect(monitor.isMonitoring)
        monitor.stop()
        monitor.stop()
        #expect(source.stopCount == 1)
        #expect(!monitor.isMonitoring)
    }

    @Test("an audio rise with a Meet tab emits joined")
    func riseJoins() async {
        let log = EventLog()
        let monitor = makeMonitor(log: log)
        inspector.enqueue(.tabs([meetTab]))
        monitor.start()
        source.emit(inOut)
        await eventually { !log.events.isEmpty }
        #expect(log.events == [.joined(meetTab)])
    }

    @Test("input off for the debounce period emits left")
    func leaveEmits() async {
        let log = EventLog()
        let monitor = makeMonitor(log: log)
        inspector.enqueue(.tabs([meetTab]))
        monitor.start()
        source.emit(inOut)
        await eventually { !log.events.isEmpty }

        clock.now = clock.now.addingTimeInterval(1)
        source.emit(.silent)
        #expect(log.events.count == 1)
        clock.now = clock.now.addingTimeInterval(4)
        source.emit(.silent)
        #expect(log.events == [.joined(meetTab), .left(code: "abc-defg-hij")])
    }

    @Test("only one query runs at a time")
    func oneQueryAtATime() async {
        let log = EventLog()
        let monitor = makeMonitor(log: log)
        inspector.hold = true
        monitor.start()
        source.emit(inOut)
        await eventually { inspector.heldCount == 1 }
        for _ in 0..<5 {
            clock.now = clock.now.addingTimeInterval(1)
            source.emit(inOut)
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(inspector.inspectCount == 1)
        inspector.release(.tabs([meetTab]))
        await eventually { !log.events.isEmpty }
        #expect(log.events == [.joined(meetTab)])
    }

    @Test("a result that arrives after stop is dropped")
    func staleResultAfterStop() async {
        let log = EventLog()
        let monitor = makeMonitor(log: log)
        inspector.hold = true
        monitor.start()
        source.emit(inOut)
        await eventually { inspector.heldCount == 1 }
        monitor.stop()
        inspector.release(.tabs([meetTab]))
        for _ in 0..<50 { await Task.yield() }
        #expect(log.events.isEmpty)
    }

    @Test("a result from before a restart is not fed to the new detector")
    func staleResultAfterRestart() async {
        let log = EventLog()
        let monitor = makeMonitor(log: log)
        inspector.hold = true
        monitor.start()
        source.emit(inOut)
        await eventually { inspector.heldCount == 1 }
        monitor.stop()
        monitor.start()
        inspector.release(.tabs([meetTab]))
        for _ in 0..<50 { await Task.yield() }
        #expect(log.events.isEmpty)
    }

    @Test("no events are delivered after stop")
    func silentAfterStop() async {
        let log = EventLog()
        let monitor = makeMonitor(log: log)
        monitor.start()
        monitor.stop()
        source.emit(inOut)
        for _ in 0..<20 { await Task.yield() }
        #expect(log.events.isEmpty)
        #expect(inspector.inspectCount == 0)
    }

    @Test("granting Automation while exhausted triggers exactly one more query")
    func permissionGrantedLater() async {
        let log = EventLog()
        let monitor = makeMonitor(log: log)
        inspector.permitted = false
        inspector.enqueue(.failed(.notAuthorized))
        inspector.enqueue(.tabs([meetTab]))
        monitor.start()
        source.emit(inOut)
        await eventually { inspector.inspectCount == 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(log.events.isEmpty)

        inspector.permitted = true
        clock.now = clock.now.addingTimeInterval(1)
        source.emit(inOut)
        await eventually { !log.events.isEmpty }
        #expect(log.events == [.joined(meetTab)])
        #expect(inspector.inspectCount == 2)
    }
}
