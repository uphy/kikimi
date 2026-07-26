import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Errors thrown by `SystemAudioSource.start(bufferHandler:)`.
///
/// Deliberately distinct from `AudioCaptureError`: `SystemAudioSource` only knows about the
/// CoreAudio Process Tap / aggregate device layer. The caller (`AudioCapture`) is responsible for
/// mapping any failure here to `.systemAudioUnavailable` and continuing to record with the
/// microphone alone (`docs/design/01-audio-capture.md` section 9, failure mode #3).
enum SystemAudioSourceError: LocalizedError, Equatable {
    case unsupportedOS
    case alreadyRunning
    case unableToCreateTap(OSStatus)
    case unableToReadTapFormat(OSStatus)
    case unableToReadTapUID(OSStatus)
    case invalidTapFormat
    case unableToCreateAggregateDevice(OSStatus)
    case unableToCreateIOProc(OSStatus)
    case failedToStartDevice(OSStatus)
    case unableToCreateConverter
    /// No IOProc callback arrived within the stall timeout while running (section 9, failure mode #5).
    case streamStalled
    /// `start(includedBundleId:)` (`docs/design/10-audio-input-selection.md` section 5.1) found zero
    /// processes matching the requested bundle id at start time. Deliberately does **not** fall back
    /// to the global exclude-list tap -- see the `includedBundleId` doc comment on `start(bufferHandler:)`.
    case selectedAppNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "System audio capture requires macOS 14.2 or later."
        case .alreadyRunning:
            return "System audio capture is already running."
        case .unableToCreateTap(let status):
            return "Failed to create the system audio process tap (OSStatus \(status))."
        case .unableToReadTapFormat(let status):
            return "Failed to read the tap format (OSStatus \(status))."
        case .unableToReadTapUID(let status):
            return "Failed to read the tap UID (OSStatus \(status))."
        case .invalidTapFormat:
            return "The system audio tap returned an invalid PCM format."
        case .unableToCreateAggregateDevice(let status):
            return "Failed to create the aggregate capture device (OSStatus \(status))."
        case .unableToCreateIOProc(let status):
            return "Failed to register the aggregate device IO callback (OSStatus \(status))."
        case .failedToStartDevice(let status):
            return "Failed to start the aggregate capture device (OSStatus \(status))."
        case .unableToCreateConverter:
            return "Failed to create an audio converter for system audio capture."
        case .streamStalled:
            return "The system audio tap stopped delivering callbacks; the device configuration likely changed."
        case .selectedAppNotRunning(let bundleId):
            return "The selected application (\(bundleId)) has no running audio processes."
        }
    }
}

/// Captures system output audio via CoreAudio's Process Tap API
/// (`AudioHardwareCreateProcessTap`) and converts it to the shared 16kHz mono Float32 std format
/// used throughout `AudioCapture`.
///
/// Supports two tap modes, selected by `includedBundleId` (`docs/design/10-audio-input-selection.md`
/// section 5.1):
///
/// - **`includedBundleId == nil`** (default, "All System Audio"): the **exclude list** tap variant
///   (`CATapDescription(monoGlobalTapButExcludeProcesses:)`, `isExclusive = true`), excluding only
///   Kikimi's own `AudioObjectID`. This targets the entirety of system output and, per the
///   Apple header's "all processes" wording, is expected to also pick up processes started *after*
///   `start()` was called -- see `docs/design/01-audio-capture.md` section 4 for the full rationale
///   and the known caveat that this dynamic-capture behavior has no Chirami precedent and is
///   unverified on real hardware (section 13, Open Questions).
/// - **`includedBundleId != nil`**: the **include list** tap variant
///   (`CATapDescription(monoMixdownOfProcesses:)`, `isExclusive = false`), targeting every process
///   whose bundle id matches at `start()` time. Unlike the exclude-list mode, this is a one-time
///   snapshot -- processes started after `start()` (e.g. the target app restarting) are not
///   captured (`docs/design/10-audio-input-selection.md` section 5.1's known caveat). This mode
///   mirrors Chirami's `SystemAudioCapture.swift` (`docs/references/chirami-map.md` section 2).
final class SystemAudioSource: AudioSourceCapturing {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SystemAudioSource")

    /// Serial queue the CoreAudio IOProc block is dispatched on. The stall-detection timer
    /// (see `stallTimer` below) is also scheduled on this queue so both share one execution
    /// context and never race with each other.
    private let ioQueue: DispatchQueue

    private let targetFormat: AVAudioFormat

    /// `AudioObjectID`s the caller wants excluded from the tap in addition to Kikimi's own
    /// process. Reserved for future per-process refinement (`docs/design/01-audio-capture.md`
    /// section 4); always empty today. Ignored when `includedBundleId != nil` (that mode uses an
    /// include list instead -- see `includedBundleId` below).
    private let additionalExcludedProcesses: [AudioObjectID]

    /// When non-`nil`, `start(bufferHandler:)` taps only the processes whose bundle id matches
    /// this value (include-list mode) instead of the default global exclude-list tap.
    /// See the class doc comment and `docs/design/10-audio-input-selection.md` section 5.1.
    private let includedBundleId: String?

    /// How long the IOProc may go quiet before this source reports itself as stalled (section 9,
    /// failure mode #5). CoreAudio's aggregate-device IOProc fires continuously at the device's
    /// buffer cadence once started -- silence in the system's audio content still produces
    /// callbacks with zero-valued samples -- so an interval this long with *zero callbacks*
    /// indicates the tap/aggregate device itself stopped working (e.g. the default output device
    /// configuration changed underneath it), not merely that nothing is currently playing.
    private let stallTimeout: TimeInterval

    private var tapID: AudioObjectID?
    private var aggregateDeviceID: AudioObjectID?
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var isRunning = false
    private var lastCallbackAt: DispatchTime = .now()
    private var stallTimer: DispatchSourceTimer?

    /// Invoked at most once (on `ioQueue`) if the tap stops delivering audio after a successful
    /// `start()` -- e.g. because the tapped device configuration changed underneath it
    /// (`docs/design/01-audio-capture.md` section 9, failure mode #5; section 13 Open Questions).
    /// `AudioCapture` is expected to treat this the same as a `.systemAudioUnavailable`
    /// degradation and keep the microphone stream running. `SystemAudioSource` fully tears itself
    /// down (as `stop()` would) before calling this, so callers do not need to call `stop()`
    /// again in response, though doing so is harmless.
    var onDegraded: (@Sendable (Error) -> Void)?

    /// - Parameters:
    ///   - includedBundleId: `nil` (default) taps all system output except Kikimi's own process
    ///     (the "All System Audio" selection). Non-`nil` switches to include-list mode, tapping
    ///     only the processes whose bundle id equals this value -- resolved fresh at `start()`
    ///     time (`docs/design/10-audio-input-selection.md` section 5.1). `excludedProcesses` is
    ///     ignored in this mode.
    ///   - excludedProcesses: Additional `AudioObjectID`s to exclude from the tap, on top of
    ///     Kikimi's own process (section 4's extension point). Always empty today. Ignored when
    ///     `includedBundleId != nil`.
    ///   - stallTimeout: How long the IOProc may go quiet before this source reports itself as
    ///     degraded via `onDegraded` (section 9, failure mode #5).
    ///   - targetSampleRate: Output sample rate after conversion (Kikimi-wide default: 16kHz).
    ///   - targetChannels: Output channel count after conversion (Kikimi-wide default: mono).
    ///   - ioQueue: Injectable for testing; defaults to a dedicated serial queue.
    init(
        includedBundleId: String? = nil,
        excludedProcesses: [AudioObjectID] = [],
        stallTimeout: TimeInterval = 5.0,
        targetSampleRate: Double = 16_000,
        targetChannels: AVAudioChannelCount = 1,
        ioQueue: DispatchQueue = DispatchQueue(label: "io.github.uphy.Kikimi.SystemAudioSource")
    ) {
        self.includedBundleId = includedBundleId
        self.additionalExcludedProcesses = excludedProcesses
        self.stallTimeout = stallTimeout
        self.ioQueue = ioQueue
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: targetChannels) else {
            preconditionFailure("Failed to construct the standard system audio output format (\(targetSampleRate)Hz, \(targetChannels)ch)")
        }
        self.targetFormat = targetFormat
    }

    deinit {
        stop()
    }

    /// Resolves the tap's process list -- the exclude list (section 4/9 failure mode #11) when
    /// `includedBundleId == nil`, or the include list matching `includedBundleId`
    /// (`docs/design/10-audio-input-selection.md` section 5.1) otherwise -- creates a private mono
    /// Process Tap targeting it, wraps it in a single-tap aggregate device, and starts an IOProc
    /// that converts each buffer to the target format.
    ///
    /// Throws `SystemAudioSourceError` on any failure; the caller (`AudioCapture`) maps this to
    /// `.systemAudioUnavailable` and continues recording with the microphone alone (section 9,
    /// failure mode #3), except `.selectedAppNotRunning` in include-list mode with no other enabled
    /// source, which is fatal (design section 5.2). Process Tap creation itself requires
    /// macOS 14.2+; on older systems this throws `.unsupportedOS`.
    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        guard #available(macOS 14.2, *) else {
            throw SystemAudioSourceError.unsupportedOS
        }
        guard !isRunning else {
            throw SystemAudioSourceError.alreadyRunning
        }

        let tapDescription: CATapDescription
        if let includedBundleId {
            let includedProcesses = try resolveIncludedProcesses(bundleId: includedBundleId)
            logger.info(
                "SystemAudioSource starting, includedBundleId=\(includedBundleId, privacy: .public) processCount=\(includedProcesses.count, privacy: .public)"
            )
            tapDescription = CATapDescription(monoMixdownOfProcesses: includedProcesses)
            tapDescription.isExclusive = false
        } else {
            let excludedProcesses = resolveExcludedProcesses()
            logger.info("SystemAudioSource starting, excludedProcesses=\(excludedProcesses.description, privacy: .public)")
            tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: excludedProcesses)
            tapDescription.isExclusive = true
        }
        tapDescription.name = "Kikimi System Audio"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var createdTapID = AudioObjectID()
        let createTapStatus = AudioHardwareCreateProcessTap(tapDescription, &createdTapID)
        guard createTapStatus == noErr else {
            throw SystemAudioSourceError.unableToCreateTap(createTapStatus)
        }

        // Tracked outside the `do` block (rather than only as a `let` local inside it) so the
        // `catch` below can destroy it on every failure path that created it -- including IOProc
        // creation failing, where `self.aggregateDeviceID` is deliberately not yet assigned (see the
        // ordering comment before `AudioDeviceStart` below), and `AudioDeviceStart` failing, where
        // `cleanup()` nils `self.aggregateDeviceID` without destroying the HAL-side device. Without
        // this, either failure leaks a private aggregate device in the HAL until the process exits
        // (`AudioHardwareCreateAggregateDevice` has no other owner to reclaim it).
        var createdAggregateDeviceID: AudioObjectID?

        do {
            let tapFormat = try readTapFormat(tapID: createdTapID)
            let tapUID = try readTapUID(tapID: createdTapID)
            guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
                throw SystemAudioSourceError.unableToCreateConverter
            }

            let aggregateDeviceID = try createAggregateDevice(tapUID: tapUID)
            createdAggregateDeviceID = aggregateDeviceID

            var createdIOProcID: AudioDeviceIOProcID?
            let createIOProcStatus = AudioDeviceCreateIOProcIDWithBlock(
                &createdIOProcID,
                aggregateDeviceID,
                ioQueue
            ) { [weak self] _, inputData, inInputTime, _, _ in
                // Capture the pre-conversion host time now, before doing any format conversion:
                // the converter's output `AVAudioPCMBuffer` cannot carry timing information, so it
                // must be read at this point and threaded through separately rather than recovered
                // afterwards (`docs/design/01-audio-capture.md` section 7.1, points 2-4).
                let hostTime = AVAudioTime(hostTime: inInputTime.pointee.mHostTime)
                self?.handleInputData(inputData, hostTime: hostTime)
            }
            guard createIOProcStatus == noErr, let createdIOProcID else {
                throw SystemAudioSourceError.unableToCreateIOProc(createIOProcStatus)
            }

            // Assign all state the IOProc callback depends on (`sourceFormat`/`converter`/
            // `bufferHandler`/`isRunning`/`lastCallbackAt`) *before* `AudioDeviceStart`, mirroring
            // `MicrophoneSource.start(bufferHandler:)`'s ordering (state set before `engine.start()`).
            // The IOProc block can start firing the instant `AudioDeviceStart` returns `noErr`, and
            // `handleInputData` silently drops any callback that arrives while these are still nil
            // -- assigning them afterwards would silently discard the first callbacks.
            self.tapID = createdTapID
            self.aggregateDeviceID = aggregateDeviceID
            self.ioProcID = createdIOProcID
            self.sourceFormat = tapFormat
            self.converter = converter
            self.bufferHandler = bufferHandler
            self.isRunning = true
            self.lastCallbackAt = .now()

            let startStatus = AudioDeviceStart(aggregateDeviceID, createdIOProcID)
            guard startStatus == noErr else {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, createdIOProcID)
                cleanup()
                throw SystemAudioSourceError.failedToStartDevice(startStatus)
            }

            startStallTimer()
        } catch {
            if let createdAggregateDeviceID {
                AudioHardwareDestroyAggregateDevice(createdAggregateDeviceID)
            }
            AudioHardwareDestroyProcessTap(createdTapID)
            throw error
        }
    }

    func stop() {
        stallTimer?.cancel()
        stallTimer = nil

        if let aggregateDeviceID, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        if let aggregateDeviceID {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if #available(macOS 14.2, *), let tapID {
            AudioHardwareDestroyProcessTap(tapID)
        }
        cleanup()
    }

    // MARK: - Self-process exclusion (section 4, failure mode #11)

    /// Resolves the tap's exclude list: Kikimi's own `AudioObjectID` plus any caller-supplied
    /// `additionalExcludedProcesses`.
    ///
    /// If Kikimi's own `AudioObjectID` cannot be resolved, this logs a `.warning` and falls back
    /// to just `additionalExcludedProcesses` (empty by default) rather than failing `start()`.
    /// Unlike Chirami's include-list `processes.isEmpty` early return
    /// (`SystemAudioCapture.swift:113-115`), an empty exclude list is a normal, fully-supported
    /// state here -- it simply means "tap every process, including Kikimi itself" -- so there is
    /// no equivalent silent no-op branch to preserve.
    private func resolveExcludedProcesses() -> [AudioObjectID] {
        guard let selfObjectID = Self.resolveSelfProcessObjectID() else {
            logger.warning("SystemAudioSource failed to resolve Kikimi's own AudioObjectID; starting with an empty exclude list")
            return additionalExcludedProcesses
        }
        return additionalExcludedProcesses + [selfObjectID]
    }

    private static func resolveSelfProcessObjectID() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var objectID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &dataSize,
            &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else {
            return nil
        }
        return objectID
    }

    // MARK: - Include-list resolution (docs/design/10-audio-input-selection.md section 5.1)

    /// Enumerates every currently registered CoreAudio process object and collects the
    /// `AudioObjectID`s whose bundle id equals `bundleId` -- including helper processes (e.g. a
    /// browser's renderer processes), all of which share the app's bundle id. Unlike
    /// `AudioInputEnumerator.systemAudioProcesses()`, this does **not** filter on
    /// `kAudioProcessPropertyIsRunningOutput`: the caller already made an explicit selection, so
    /// every matching process is tapped regardless of whether it happens to be producing output at
    /// this exact instant.
    ///
    /// Throws `.selectedAppNotRunning` if no process currently has this bundle id. Deliberately
    /// does not fall back to the global exclude-list tap -- see the class doc comment.
    private func resolveIncludedProcesses(bundleId: String) throws -> [AudioObjectID] {
        let matching = Self.processObjectIDs(matchingBundleId: bundleId)
        guard !matching.isEmpty else {
            throw SystemAudioSourceError.selectedAppNotRunning(bundleId)
        }
        return matching
    }

    private static func processObjectIDs(matchingBundleId targetBundleId: String) -> [AudioObjectID] {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr else {
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
            return []
        }

        return processObjectIDs.filter { readProcessBundleID(objectID: $0) == targetBundleId }
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

    // MARK: - Stall detection (section 9 failure mode #5, section 13 Open Questions)

    /// Periodically checks, on `ioQueue`, whether the IOProc has gone quiet for longer than
    /// `stallTimeout`.
    ///
    /// Chosen over monitoring `kAudioObjectSystemObject` device-changed notifications (the other
    /// option this design left open) because a single timeout-based check catches every cause of
    /// a stopped callback stream -- default device changes, the aggregate device or tap being
    /// torn down out from under this instance, etc. -- without needing to enumerate and subscribe
    /// to each specific CoreAudio property that could signal one of those causes.
    private func startStallTimer() {
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + stallTimeout, repeating: stallTimeout)
        timer.setEventHandler { [weak self] in
            self?.checkForStallOnQueue()
        }
        timer.resume()
        stallTimer = timer
    }

    private func checkForStallOnQueue() {
        guard isRunning else {
            return
        }
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - lastCallbackAt.uptimeNanoseconds
        guard Double(elapsedNanoseconds) / 1_000_000_000 >= stallTimeout else {
            return
        }

        logger.warning("SystemAudioSource saw no IOProc callbacks for \(self.stallTimeout, privacy: .public)s; reporting system audio as degraded")
        let handler = onDegraded
        stop()
        handler?(SystemAudioSourceError.streamStalled)
    }

    // MARK: - Tap / aggregate device setup (mirrors Chirami's SystemAudioCapture.swift)

    @available(macOS 14.2, *)
    private func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let aggregateUID = UUID().uuidString
        let subTapDescription: [String: Any] = [
            "uid": tapUID,
            "drift": 0
        ]
        let description: [String: Any] = [
            "uid": aggregateUID,
            "name": "Kikimi System Audio Capture",
            "private": 1,
            "taps": [subTapDescription],
            "tapautostart": 1
        ]

        var deviceID = AudioObjectID()
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr else {
            throw SystemAudioSourceError.unableToCreateAggregateDevice(status)
        }
        return deviceID
    }

    @available(macOS 14.2, *)
    private func readTapFormat(tapID: AudioObjectID) throws -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &asbd)
        guard status == noErr else {
            throw SystemAudioSourceError.unableToReadTapFormat(status)
        }

        var mutableASBD = asbd
        guard
            asbd.mFormatID == kAudioFormatLinearPCM,
            let format = AVAudioFormat(streamDescription: &mutableASBD)
        else {
            throw SystemAudioSourceError.invalidTapFormat
        }
        return format
    }

    @available(macOS 14.2, *)
    private func readTapUID(tapID: AudioObjectID) throws -> String {
        var tapUID: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &tapUID)
        guard status == noErr else {
            throw SystemAudioSourceError.unableToReadTapUID(status)
        }

        return tapUID as String
    }

    // MARK: - Buffer conversion (section 7.1)

    private func handleInputData(_ inputData: UnsafePointer<AudioBufferList>?, hostTime: AVAudioTime) {
        lastCallbackAt = .now()

        guard
            let inputData,
            let sourceFormat,
            let converter,
            let bufferHandler
        else {
            return
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            bufferListNoCopy: inputData,
            deallocator: nil
        ) else {
            return
        }

        let sourceASBD = sourceFormat.streamDescription.pointee
        guard sourceASBD.mBytesPerFrame > 0 else {
            return
        }

        let firstBuffer = inputData.pointee.mBuffers
        let frameLength = AVAudioFrameCount(firstBuffer.mDataByteSize) / sourceASBD.mBytesPerFrame
        guard frameLength > 0 else {
            return
        }
        inputBuffer.frameLength = frameLength

        let outputFrameCapacity = max(
            AVAudioFrameCount(frameLength),
            max(
                1,
                AVAudioFrameCount(ceil(Double(frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate))
            )
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            logger.warning("failed to allocate system audio output buffer; dropping this buffer")
            return
        }

        var conversionError: NSError?
        var providedInput = false
        // Single-shot pattern: the converter is fed `inputBuffer` exactly once and reports
        // `.noDataNow` afterwards, so one call to `convert` yields exactly the frames that
        // correspond to this one input buffer's time span (section 7.1, point 3) -- no
        // frame-level apportionment is needed for the `hostTime` forwarded below.
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if providedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            outputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil else {
            // Drop this single buffer and keep processing subsequent ones (section 9, failure
            // mode #6). Unlike Chirami (which drops silently), Kikimi always logs the drop.
            logger.warning("system audio buffer conversion dropped: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }
        guard outputBuffer.frameLength > 0 else {
            return
        }

        bufferHandler(outputBuffer, hostTime)
    }

    private func cleanup() {
        tapID = nil
        aggregateDeviceID = nil
        ioProcID = nil
        converter = nil
        sourceFormat = nil
        bufferHandler = nil
        isRunning = false
    }
}
