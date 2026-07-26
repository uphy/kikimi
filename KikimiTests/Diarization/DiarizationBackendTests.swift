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
