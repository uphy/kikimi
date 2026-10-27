import AVFoundation
import CoreAudio
import OSLog

/// Helpers `MicrophoneSource.start` uses to recover from an input node that reports no usable format
/// before giving up. Seen on 2026-10-27: after four days of uptime and an input-device change, every
/// recording start failed with `sampleRate=0, channelCount=0` while a fresh process opened the same
/// microphone at 48 kHz. Rebinding the node to the current default input, and failing that building a
/// fresh `AVAudioEngine`, is the in-process equivalent of that restart.
enum MicrophoneInputRecovery {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "MicrophoneSource")

    /// Reads `inputNode`'s format, reloading the device when it is unusable: first rebinding the node to
    /// the current default input (only when `followsDefault`), then replacing `engine` with a fresh one
    /// and re-running `configure` on its input node. Returns the last format read, usable or not.
    static func usableFormat(
        engine: inout AVAudioEngine,
        inputNode: inout AVAudioInputNode,
        makeEngine: () -> AVAudioEngine,
        followsDefault: Bool,
        configure: (AVAudioInputNode) -> Void
    ) -> AVAudioFormat {
        var format = inputNode.inputFormat(forBus: 0)
        if !isUsable(format), followsDefault, let defaultID = currentDefaultInputDeviceID() {
            logger.warning("input format is invalid (\(describe(format), privacy: .public)); rebinding to the current default input")
            bind(inputNode, to: defaultID)
            format = inputNode.inputFormat(forBus: 0)
        }
        if !isUsable(format) {
            logger.warning("input format is still invalid (\(describe(format), privacy: .public)); rebuilding the audio engine")
            engine = makeEngine()
            inputNode = engine.inputNode
            configure(inputNode)
            format = inputNode.inputFormat(forBus: 0)
        }
        if isUsable(format) {
            logger.info("microphone input format: \(describe(format), privacy: .public)")
        }
        return format
    }

    static func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    static func describe(_ format: AVAudioFormat) -> String {
        "sampleRate=\(format.sampleRate), channelCount=\(format.channelCount)"
    }

    /// The system default input device as CoreAudio reports it right now, or `nil` when there is none.
    static func currentDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Points `inputNode`'s audio unit at `deviceID`. Returns `false` when the unit is unavailable or
    /// rejects the device.
    @discardableResult
    static func bind(_ inputNode: AVAudioInputNode, to deviceID: AudioDeviceID) -> Bool {
        guard let audioUnit = inputNode.audioUnit else { return false }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }
}
