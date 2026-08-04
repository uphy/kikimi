import Foundation
import Testing

@testable import Kikimi

/// `docs/design/49-dictation-hud-slim.md` §5 (1-3): the pure half of the HUD's level meter. With
/// the live transcript gone, these bars are the only thing telling the user the mic is working, so
/// the two properties that carry that meaning -- silence reads as zero, and the response is
/// monotonic -- are asserted directly.
@Suite("DictationAudioLevelMeter")
struct DictationAudioLevelMeterTests {
    private let tolerance: Float = 0.0001

    @Test("rms: an empty buffer is silence, not a NaN")
    func rmsOfEmptyBuffer() {
        #expect(DictationAudioLevelMeter.rms([]) == 0)
    }

    @Test("rms: digital silence is zero")
    func rmsOfSilence() {
        #expect(DictationAudioLevelMeter.rms([Float](repeating: 0, count: 512)) == 0)
    }

    @Test("rms: a full-scale square wave is 1, a half-scale one is 0.5 (sign-independent)")
    func rmsOfSquareWaves() {
        let fullScale: [Float] = [1, -1, 1, -1]
        let halfScale: [Float] = [0.5, -0.5, 0.5, -0.5]

        #expect(abs(DictationAudioLevelMeter.rms(fullScale) - 1) < tolerance)
        #expect(abs(DictationAudioLevelMeter.rms(halfScale) - 0.5) < tolerance)
    }

    @Test("normalize: silence is 0 and full scale is 1")
    func normalizeEndpoints() {
        #expect(DictationAudioLevelMeter.normalize(rms: 0) == 0)
        #expect(DictationAudioLevelMeter.normalize(rms: 1) == 1)
        // Above full scale (possible with a hot input) clamps rather than overshooting the bars.
        #expect(DictationAudioLevelMeter.normalize(rms: 4) == 1)
    }

    @Test("normalize: at or below the -50dB floor the bars stay still")
    func normalizeFloor() {
        let atFloor = pow(10, DictationAudioLevelMeter.floorDb / 20)

        #expect(DictationAudioLevelMeter.normalize(rms: atFloor) == 0)
        #expect(DictationAudioLevelMeter.normalize(rms: atFloor / 2) == 0)
        #expect(DictationAudioLevelMeter.normalize(rms: atFloor * 2) > 0)
    }

    @Test("normalize: -25dB (half the dB range) lands mid-scale")
    func normalizeMidScale() {
        let halfway = pow(10, (DictationAudioLevelMeter.floorDb / 2) / 20)

        #expect(abs(DictationAudioLevelMeter.normalize(rms: halfway) - 0.5) < tolerance)
    }

    @Test("normalize: never decreases as the input grows")
    func normalizeIsMonotonic() {
        var previous: Float = -1
        for step in 0 ... 100 {
            let value = DictationAudioLevelMeter.normalize(rms: Float(step) / 100)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test("Smoother: rises faster than it falls")
    func smootherIsAsymmetric() {
        var rising = DictationAudioLevelMeter.Smoother()
        let afterOneRise = rising.update(1)

        var falling = DictationAudioLevelMeter.Smoother()
        _ = falling.update(1)
        while falling.value < 0.99 {
            _ = falling.update(1)
        }
        let beforeFall = falling.value
        let afterOneFall = falling.update(0)

        #expect(afterOneRise > 0)
        #expect(afterOneRise < 1)
        // The same one-step distance travelled, measured against each direction's full gap.
        #expect(afterOneRise > beforeFall - afterOneFall)
    }

    @Test("Smoother: converges on a held level and returns to 0 on reset")
    func smootherConverges() {
        var smoother = DictationAudioLevelMeter.Smoother()
        for _ in 0 ..< 200 {
            _ = smoother.update(0.6)
        }

        #expect(abs(smoother.value - 0.6) < 0.01)

        smoother.reset()
        #expect(smoother.value == 0)
    }
}
