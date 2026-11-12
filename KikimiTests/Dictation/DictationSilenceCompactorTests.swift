import Testing

@testable import Kikimi

/// `docs/design/51-dictation-silence-skip.md` §4: the pure range arithmetic behind SS3-SS6.
/// Frames are 1,000 samples and the parameters are scaled to match, so the expected ranges read
/// directly off the probability arrays.
@Suite("DictationSilenceCompactor")
struct DictationSilenceCompactorTests {
    private static let frame = 1_000
    private static let parameters = DictationSilenceCompactor.Parameters(
        speechThreshold: 0.5,
        paddingSamples: 200,
        minSilenceSamples: 800,
        keptGapSamples: 100,
        minSavedSamples: 1_000
    )

    /// Each sample holds its own index, so the output shows exactly which samples were kept.
    private func indexedSamples(frames: Int) -> [Float] {
        (0..<(frames * Self.frame)).map(Float.init)
    }

    private func compact(_ probabilities: [Float]) -> DictationSilenceCompactor.Result? {
        DictationSilenceCompactor.compact(
            samples: indexedSamples(frames: probabilities.count),
            probabilities: probabilities,
            frameSampleCount: Self.frame,
            parameters: Self.parameters
        )
    }

    @Test("SS3/SS5: leading, middle and trailing silences are cut, keeping padding")
    func cutsLeadingMiddleAndTrailingSilence() throws {
        // speech in frames 2 and 7 of 10
        let result = try #require(compact([0, 0, 0.9, 0, 0, 0, 0, 0.9, 0, 0]))
        #expect(result.keptRanges == [1_800..<3_200, 6_800..<8_200])
        #expect(result.samples.count == 1_400 + 100 + 1_400)
    }

    @Test("SS4: a zero gap of keptGapSamples sits where the silence was cut")
    func insertsZeroGapAtCut() throws {
        let result = try #require(compact([0, 0, 0.9, 0, 0, 0, 0, 0.9, 0, 0]))
        #expect(result.samples[1_399] == 3_199)
        #expect(result.samples[1_400..<1_500].allSatisfy { $0 == 0 })
        #expect(result.samples[1_500] == 6_800)
    }

    @Test("SS3: padded runs closer than minSilenceSamples are joined, not cut")
    func joinsShortPauses() throws {
        // frames 2 and 4: padded ranges 1,800..<3,200 and 3,800..<5,200 are 600 apart (< 800)
        let result = try #require(compact([0, 0, 0.9, 0, 0.9, 0, 0, 0, 0, 0]))
        #expect(result.keptRanges == [1_800..<5_200])
    }

    @Test("padding is clamped to the audio's ends")
    func clampsPaddingAtEnds() throws {
        let result = try #require(compact([0.9, 0, 0, 0, 0, 0, 0, 0, 0, 0.9]))
        #expect(result.keptRanges == [0..<1_200, 8_800..<10_000])
    }

    @Test("probabilities exactly at the threshold count as speech")
    func thresholdIsInclusive() throws {
        let result = try #require(compact([0, 0, 0.5, 0, 0, 0, 0, 0, 0, 0]))
        #expect(result.keptRanges == [1_800..<3_200])
    }

    @Test("SS6 (1): no speech frame at all returns nil")
    func noSpeechReturnsNil() {
        #expect(compact([0, 0.1, 0.49, 0, 0, 0, 0, 0, 0, 0]) == nil)
    }

    @Test("SS6 (2): a saving below minSavedSamples returns nil")
    func smallSavingReturnsNil() {
        // speech in every frame but the last: at most 800 samples could go
        #expect(compact([0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0]) == nil)
    }

    @Test("a short final frame is clamped to the sample count")
    func shortFinalFrame() throws {
        let samples = [Float](repeating: 1, count: 9_500)
        let result = try #require(DictationSilenceCompactor.compact(
            samples: samples,
            probabilities: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0.9],
            frameSampleCount: Self.frame,
            parameters: Self.parameters
        ))
        #expect(result.keptRanges == [8_800..<9_500])
    }

    @Test("the default threshold keeps quiet frames that stay below 0.5")
    func defaultThresholdKeepsQuietSpeech() {
        #expect(DictationSilenceCompactor.Parameters.default.speechThreshold == 0.35)
        let samples = [Float](repeating: 1, count: 20 * 4_096)
        var probabilities = [Float](repeating: 0, count: 20)
        probabilities[10] = 0.4
        let result = DictationSilenceCompactor.compact(
            samples: samples, probabilities: probabilities, frameSampleCount: 4_096)
        #expect(result?.keptRanges == [(10 * 4_096 - 4_800)..<(11 * 4_096 + 4_800)])
    }

    @Test("empty samples return nil")
    func emptySamples() {
        #expect(DictationSilenceCompactor.compact(
            samples: [], probabilities: [0.9], frameSampleCount: Self.frame, parameters: Self.parameters) == nil)
    }
}
