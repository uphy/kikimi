import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `AudioInputEnumerator.aggregateProcesses(_:)`, the pure
/// filter/dedupe step described in `docs/design/10-audio-input-selection.md` section 2:
/// only processes currently producing output are kept, processes without a bundle id are
/// dropped, and processes sharing a bundle id collapse into a single `AudioProcessInfo`.
/// CoreAudio enumeration itself (`inputDevices()`/`systemAudioProcesses()`) is out of scope
/// for unit testing per the module brief.
@Suite("AudioInputEnumerator.aggregateProcesses")
struct AudioInputEnumeratorTests {
    private typealias Observation = AudioInputEnumerator.RawProcessObservation

    @Test("keeps a single running-output process with a bundle id")
    func keepsSingleRunningOutputProcess() {
        let observations = [
            Observation(bundleId: "us.zoom.xos", displayName: "zoom.us", isRunningOutput: true)
        ]

        let result = AudioInputEnumerator.aggregateProcesses(observations)

        #expect(result == [AudioProcessInfo(bundleId: "us.zoom.xos", displayName: "zoom.us")])
    }

    @Test("drops processes that are not currently running output")
    func dropsNonRunningOutputProcesses() {
        let observations = [
            Observation(bundleId: "us.zoom.xos", displayName: "zoom.us", isRunningOutput: false)
        ]

        #expect(AudioInputEnumerator.aggregateProcesses(observations).isEmpty)
    }

    @Test("drops processes without a bundle id")
    func dropsProcessesWithoutBundleId() {
        let observations = [
            Observation(bundleId: nil, displayName: "Some Helper", isRunningOutput: true),
            Observation(bundleId: "", displayName: "Empty Bundle Id", isRunningOutput: true)
        ]

        #expect(AudioInputEnumerator.aggregateProcesses(observations).isEmpty)
    }

    @Test("collapses multiple processes sharing a bundle id into one entry")
    func collapsesSharedBundleId() {
        // e.g. a browser's helper processes: same bundle id, several running-output processes.
        let observations = [
            Observation(bundleId: "company.thebrowser.browser", displayName: "Arc", isRunningOutput: true),
            Observation(bundleId: "company.thebrowser.browser", displayName: "Arc Helper", isRunningOutput: true),
            Observation(bundleId: "company.thebrowser.browser", displayName: "Arc Helper (Renderer)", isRunningOutput: true)
        ]

        let result = AudioInputEnumerator.aggregateProcesses(observations)

        #expect(result.count == 1)
        #expect(result.first?.bundleId == "company.thebrowser.browser")
        // Keeps the display name from the first observation encountered for the bundle id.
        #expect(result.first?.displayName == "Arc")
    }

    @Test("falls back to the bundle id as display name when no application name is available")
    func fallsBackToBundleIdForDisplayName() {
        let observations = [
            Observation(bundleId: "com.example.headless", displayName: nil, isRunningOutput: true),
            Observation(bundleId: "com.example.other", displayName: "", isRunningOutput: true)
        ]

        let result = AudioInputEnumerator.aggregateProcesses(observations)

        #expect(result.contains(AudioProcessInfo(bundleId: "com.example.headless", displayName: "com.example.headless")))
        #expect(result.contains(AudioProcessInfo(bundleId: "com.example.other", displayName: "com.example.other")))
    }

    @Test("sorts the result by display name")
    func sortsByDisplayName() {
        let observations = [
            Observation(bundleId: "us.zoom.xos", displayName: "Zoom", isRunningOutput: true),
            Observation(bundleId: "company.thebrowser.browser", displayName: "Arc", isRunningOutput: true),
            Observation(bundleId: "com.apple.Music", displayName: "Music", isRunningOutput: true)
        ]

        let result = AudioInputEnumerator.aggregateProcesses(observations)

        #expect(result.map(\.displayName) == ["Arc", "Music", "Zoom"])
    }

    @Test("returns an empty list for empty input")
    func returnsEmptyForEmptyInput() {
        #expect(AudioInputEnumerator.aggregateProcesses([]).isEmpty)
    }
}
