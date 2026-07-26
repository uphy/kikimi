import AppKit
import AVFoundation
import CoreAudio
import Foundation
import OSLog

// MARK: - AudioDeviceInfo

/// One selectable microphone input device.
/// See `docs/design/10-audio-input-selection.md` section 2.
struct AudioDeviceInfo: Equatable, Identifiable, Sendable {
    var id: String { uid }
    let uid: String
    let name: String
}

// MARK: - AudioProcessInfo

/// One selectable application for system audio capture, deduped by bundle id across its
/// (possibly several) running processes. See `docs/design/10-audio-input-selection.md` section 2.
struct AudioProcessInfo: Equatable, Identifiable, Sendable {
    var id: String { bundleId }
    let bundleId: String
    /// `NSRunningApplication.localizedName`, falling back to `bundleId` when unavailable.
    let displayName: String
}

// MARK: - AudioInputEnumerating

/// Stateless enumeration of selectable inputs; every call reads the current system state (no
/// caching, no change notifications -- callers re-enumerate on demand, e.g. each time the input
/// popover opens; see `docs/design/10-audio-input-selection.md` section 2).
///
/// Protocol-backed so view-model tests can fake both lists, mirroring the `AudioSourceCapturing`
/// DI pattern used elsewhere in `AudioCapture`.
protocol AudioInputEnumerating: Sendable {
    /// All available microphone input devices (`AVCaptureDevice.DiscoverySession`, mic + external).
    func inputDevices() -> [AudioDeviceInfo]

    /// Applications currently producing system audio output, one entry per distinct bundle id.
    /// This is the list shown in the input popover's Picker (`docs/design/10-audio-input-selection.md`
    /// section 7.2): deliberately narrowed to apps that are *audibly* running right now, so the
    /// picker doesn't fill up with every process CoreAudio has ever registered.
    func systemAudioProcesses() -> [AudioProcessInfo]

    /// Every currently registered CoreAudio process with a resolvable bundle id, one entry per
    /// distinct bundle id, **regardless of whether it is producing audio output at this exact
    /// instant**. Used to validate a persisted `SystemAudioSelection.bundleId` at recording start
    /// (`docs/design/10-audio-input-selection.md` section 4 ②) against the same basis
    /// `SystemAudioSource.resolveIncludedProcesses` itself uses to decide whether a selected app can
    /// be tapped (`SystemAudioSource.processObjectIDs(matchingBundleId:)`, which does not filter on
    /// `kAudioProcessPropertyIsRunningOutput`). Using `systemAudioProcesses()`'s output-filtered list
    /// for this check instead would destructively reset a valid selection (e.g. "Zoom", launched but
    /// not yet producing audio) back to "All System Audio" purely because the meeting hasn't started
    /// making noise yet -- see the design doc's review notes on this failure mode.
    func registeredSystemAudioApps() -> [AudioProcessInfo]
}

// MARK: - AudioInputEnumerator

/// Default `AudioInputEnumerating` implementation.
///
/// Mic enumeration is modeled closely on Chirami's `AudioDeviceEnumerator.swift`
/// (`AVCaptureDevice.DiscoverySession`; `uniqueID` doubles as the CoreAudio device UID).
///
/// Process enumeration is modeled closely on Chirami's `AudioProcessEnumerator.swift`
/// (`kAudioHardwarePropertyProcessObjectList` -> `kAudioProcessPropertyPID` /
/// `kAudioProcessPropertyBundleID` / `NSRunningApplication` for the display name ->
/// `kAudioProcessPropertyIsRunningOutput` to keep only processes currently producing audio
/// output), with two Kikimi-specific differences (section 2): processes without a bundle id are
/// dropped entirely (bundle id is the persistence key -- see `AudioInputSelection`), and
/// processes sharing a bundle id (e.g. a browser's helper processes) collapse into a single
/// `AudioProcessInfo`. The dedupe/filter step is factored out as `aggregateProcesses(_:)` so it
/// can be unit tested without touching CoreAudio.
struct AudioInputEnumerator: AudioInputEnumerating {
    /// One raw CoreAudio process observation, before the bundle-id filter/dedupe pass. Exposed
    /// internally (rather than private) so `aggregateProcesses(_:)` can be exercised directly in
    /// tests with fabricated data, per `docs/design/10-audio-input-selection.md` section 9's
    /// requirement that the enumerator's aggregation logic be pure-function testable.
    struct RawProcessObservation: Equatable, Sendable {
        let bundleId: String?
        let displayName: String?
        let isRunningOutput: Bool
    }

    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "AudioInputEnumerator")

    init() {}

    func inputDevices() -> [AudioDeviceInfo] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
            .map { device in
                AudioDeviceInfo(uid: device.uniqueID, name: device.localizedName)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func systemAudioProcesses() -> [AudioProcessInfo] {
        Self.aggregateProcesses(readRawProcessObservations())
    }

    func registeredSystemAudioApps() -> [AudioProcessInfo] {
        Self.aggregateProcesses(readRawProcessObservations(), filterRunningOutput: false)
    }

    /// Drops any observation without a bundle id (the persistence key -- section 2), and collapses
    /// processes sharing a bundle id into one `AudioProcessInfo`, keeping the display name from the
    /// first observation encountered for that bundle id. Result is sorted by display name
    /// (`docs/design/10-audio-input-selection.md` section 7.2: Picker entries listed in name order).
    ///
    /// - Parameter filterRunningOutput: `true` (the `systemAudioProcesses()` default) additionally
    ///   requires `isRunningOutput`, matching Chirami's `AudioProcessEnumerator.swift` and section
    ///   2's Picker rationale. `false` (`registeredSystemAudioApps()`) keeps every registered process
    ///   with a bundle id regardless of output state -- see that method's doc comment for why this
    ///   distinction matters for recording-start bundle-id resolution.
    static func aggregateProcesses(_ observations: [RawProcessObservation], filterRunningOutput: Bool = true) -> [AudioProcessInfo] {
        var seenBundleIds = Set<String>()
        var result: [AudioProcessInfo] = []

        for observation in observations {
            if filterRunningOutput {
                guard observation.isRunningOutput else { continue }
            }
            guard let bundleId = observation.bundleId, !bundleId.isEmpty else { continue }
            guard seenBundleIds.insert(bundleId).inserted else { continue }

            let displayName = observation.displayName?.isEmpty == false ? observation.displayName! : bundleId
            result.append(AudioProcessInfo(bundleId: bundleId, displayName: displayName))
        }

        return result.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - CoreAudio process enumeration

    private func readRawProcessObservations() -> [RawProcessObservation] {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr else {
            logger.warning("failed to read process object list size")
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else {
            return []
        }

        var processObjectIDs = Array(repeating: AudioObjectID(), count: count)
        guard AudioObjectGetPropertyData(
            systemObjectID,
            &address,
            0,
            nil,
            &dataSize,
            &processObjectIDs
        ) == noErr else {
            logger.warning("failed to read process object list")
            return []
        }

        return processObjectIDs.map(observation(forProcessObject:))
    }

    private func observation(forProcessObject objectID: AudioObjectID) -> RawProcessObservation {
        let bundleId = Self.readProcessBundleID(objectID: objectID)
        let displayName = Self.readProcessPID(objectID: objectID)
            .flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        let isRunningOutput = Self.readProcessState(objectID: objectID, selector: kAudioProcessPropertyIsRunningOutput)

        return RawProcessObservation(bundleId: bundleId, displayName: displayName, isRunningOutput: isRunningOutput)
    }

    private static func readProcessPID(objectID: AudioObjectID) -> pid_t? {
        var value = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func readProcessBundleID(objectID: AudioObjectID) -> String? {
        var bundleID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &bundleID) == noErr else {
            return nil
        }
        return bundleID as String
    }

    private static func readProcessState(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }
}
