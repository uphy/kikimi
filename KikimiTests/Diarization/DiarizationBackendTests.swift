import FluidAudio
import Foundation
import OSLog
import Testing

@testable import Kikimi

/// Unit tests for `LSEENDStepSize.fromDiarizationConfig(stepMs:logger:)`
/// (`Kikimi/Diarization/DiarizationBackend.swift`), the config.yaml `diarization.step_ms` ->
/// FluidAudio `LSEENDStepSize` conversion (`docs/design/13-speaker-diarization.md` section 7).
/// Regression coverage for the review finding that `DiarizationConfig.stepMs` was never actually
/// wired into `LSEENDDiarizationBackend` -- this is the pure-function seam that wiring depends on.
@Suite("LSEENDStepSize+DiarizationConfig")
struct DiarizationBackendTests {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DiarizationBackendTests")

    @Test("100 maps to .step100ms")
    func mapsOneHundred() {
        #expect(LSEENDStepSize.fromDiarizationConfig(stepMs: 100, logger: logger) == .step100ms)
    }

    @Test("500 maps to .step500ms")
    func mapsFiveHundred() {
        #expect(LSEENDStepSize.fromDiarizationConfig(stepMs: 500, logger: logger) == .step500ms)
    }

    @Test("an unsupported value falls back to .step500ms rather than crashing")
    func unsupportedValueFallsBackToFiveHundred() {
        #expect(LSEENDStepSize.fromDiarizationConfig(stepMs: 250, logger: logger) == .step500ms)
        #expect(LSEENDStepSize.fromDiarizationConfig(stepMs: 0, logger: logger) == .step500ms)
        #expect(LSEENDStepSize.fromDiarizationConfig(stepMs: -1, logger: logger) == .step500ms)
    }

    @Test("every supported variant name maps to its LSEENDVariant, case-insensitively")
    func mapsVariantNames() {
        #expect(LSEENDVariant.fromDiarizationConfig(name: "callhome", logger: logger) == .callhome)
        #expect(LSEENDVariant.fromDiarizationConfig(name: "dihard3", logger: logger) == .dihard3)
        #expect(LSEENDVariant.fromDiarizationConfig(name: "dihard2", logger: logger) == .dihard2)
        #expect(LSEENDVariant.fromDiarizationConfig(name: "ami", logger: logger) == .ami)
        #expect(LSEENDVariant.fromDiarizationConfig(name: "CallHome", logger: logger) == .callhome)
    }

    @Test("an unknown variant name falls back to .callhome rather than crashing")
    func unknownVariantFallsBackToCallhome() {
        #expect(LSEENDVariant.fromDiarizationConfig(name: "sortformer", logger: logger) == .callhome)
        #expect(LSEENDVariant.fromDiarizationConfig(name: "", logger: logger) == .callhome)
    }
}

/// Unit tests for the pure `DiarizerTimelineConfig` construction seam
/// (`LSEENDDiarizationBackend.timelineFrames(ms:frameDurationSeconds:)` /
/// `.makeTimelineConfig(frameDurationSeconds:...)`), which is what `initialize()` calls once the real
/// model's `metadata.frameDurationSeconds` is known. Splitting the ms → frame conversion out of
/// `initialize()` is exactly what makes it testable here: loading a real LS-EEND model needs CoreML and
/// a HuggingFace download, neither of which layer-1 tests may do
/// (`docs/design/13-speaker-diarization.md` section 11).
@Suite("LSEENDDiarizationBackend timeline config")
struct LSEENDTimelineConfigTests {
    @Test("ms is converted to frames against the model's own frame duration, rounded to nearest")
    func msConvertsToFramesAgainstFrameDuration() {
        // 0.1 s frames (LS-EEND's actual frame rate): 250ms -> 2.5 frames -> 3 (round half away from
        // zero, matching FluidAudio's own `Int(round(seconds / frameDurationSeconds))` accessors).
        #expect(LSEENDDiarizationBackend.timelineFrames(ms: 250, frameDurationSeconds: 0.1) == 3)
        #expect(LSEENDDiarizationBackend.timelineFrames(ms: 300, frameDurationSeconds: 0.1) == 3)
        #expect(LSEENDDiarizationBackend.timelineFrames(ms: 1_000, frameDurationSeconds: 0.1) == 10)
        // A different frame duration must produce a different frame count for the same ms -- the whole
        // reason `initialize()` cannot build the config before the model is loaded.
        #expect(LSEENDDiarizationBackend.timelineFrames(ms: 250, frameDurationSeconds: 0.08) == 3)
        #expect(LSEENDDiarizationBackend.timelineFrames(ms: 1_000, frameDurationSeconds: 0.08) == 13)
    }

    @Test("a non-positive ms or frame duration yields 0 frames (FluidAudio's pass-through value) instead of dividing by zero")
    func nonPositiveInputsYieldZeroFrames() {
        #expect(LSEENDDiarizationBackend.timelineFrames(ms: 0, frameDurationSeconds: 0.1) == 0)
        #expect(LSEENDDiarizationBackend.timelineFrames(ms: -250, frameDurationSeconds: 0.1) == 0)
        #expect(LSEENDDiarizationBackend.timelineFrames(ms: 250, frameDurationSeconds: 0) == 0)
        #expect(LSEENDDiarizationBackend.timelineFrames(ms: 250, frameDurationSeconds: -0.1) == 0)
    }

    @Test("makeTimelineConfig carries the configured thresholds and converts both duration gates")
    func makeTimelineConfigCarriesConfiguredValues() {
        let config = LSEENDDiarizationBackend.makeTimelineConfig(
            frameDurationSeconds: 0.1,
            onsetThreshold: 0.7,
            offsetThreshold: 0.4,
            minDurationOnMs: 250,
            minDurationOffMs: 500
        )

        #expect(config.frameDurationSeconds == 0.1)
        #expect(config.onsetThreshold == 0.7)
        #expect(config.offsetThreshold == 0.4)
        #expect(config.minFramesOn == 3)
        #expect(config.minFramesOff == 5)
        // The seconds accessors read back the configured durations, which is the property that was
        // broken when the config was built before the model's frame duration was known.
        #expect(abs(config.minDurationOn - 0.3) < 0.0001)
        #expect(abs(config.minDurationOff - 0.5) < 0.0001)
        // Padding stays at FluidAudio's pass-through 0 -- padding widens turns, the opposite of what
        // the duration gates exist for.
        #expect(config.onsetPadFrames == 0)
        #expect(config.offsetPadFrames == 0)
    }

    @Test("DiarizationConfig.default's timeline values produce a non-pass-through config (the bug this fixes)")
    func defaultConfigIsNotPassThrough() {
        let config = LSEENDDiarizationBackend.makeTimelineConfig(
            frameDurationSeconds: 0.1,
            onsetThreshold: DiarizationConfig.default.onsetThreshold,
            offsetThreshold: DiarizationConfig.default.offsetThreshold,
            minDurationOnMs: DiarizationConfig.default.minDurationOnMs,
            minDurationOffMs: DiarizationConfig.default.minDurationOffMs
        )

        // FluidAudio's own `DiarizerTimelineConfig.default` leaves every frame count at 0, which is
        // what let 0.2s phantom turns through before this wiring existed.
        #expect(config.minFramesOn > 0)
        #expect(config.minFramesOff > 0)
    }

    @Test("a 0 duration gate stays 0 frames, restoring FluidAudio's pass-through behavior on request")
    func zeroDurationGateStaysPassThrough() {
        let config = LSEENDDiarizationBackend.makeTimelineConfig(
            frameDurationSeconds: 0.1,
            onsetThreshold: 0.5,
            offsetThreshold: 0.5,
            minDurationOnMs: 0,
            minDurationOffMs: 0
        )

        #expect(config.minFramesOn == 0)
        #expect(config.minFramesOff == 0)
    }
}
