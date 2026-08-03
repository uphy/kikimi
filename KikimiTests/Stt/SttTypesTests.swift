import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `SttTypes.swift` (`docs/design/11-streaming-stt.md` section 3.2/3.3/3.4/3.5/3.7).
/// Covers the plain-data types and their documented default values; the segment-confirmation/chunk
/// accumulation pure logic lives in `SttEngine+PureHelpers.swift` and is exercised directly.
@Suite("SttEngineConfig")
struct SttEngineConfigTests {
    @Test("defaults match section 3.9's config.yaml mapping (spike chunkTierDocs: 2240ms recommended for ja)")
    func defaults() {
        let config = SttEngineConfig()

        #expect(config.language == "ja-JP")
        #expect(config.chunkMs == 2_240)
        #expect(config.segmentIdleTimeout == 2.0)
        #expect(config.maxSegmentCharacters == 120)
        // MT10: default ON -- opt-in would leave the word-drop fix silently unapplied for most
        // sessions (`docs/design/33-meeting-two-pass-decode.md`).
        #expect(config.twoPassDecode == true)
    }

    @Test("sentenceEndingCharacters covers both full-width and half-width terminators (section 3.3 route 1)")
    func sentenceEndingCharacters() {
        let chars = SttEngineConfig.sentenceEndingCharacters
        #expect(chars.contains("。"))
        #expect(chars.contains("？"))
        #expect(chars.contains("！"))
        #expect(chars.contains("?"))
        #expect(chars.contains("!"))
        #expect(!chars.contains("、"))
    }

    @Test("validChunkMsTiers matches FluidAudio's four supported tiers (section 3.9)")
    func validChunkMsTiers() {
        #expect(SttEngineConfig.validChunkMsTiers == [560, 1_120, 2_240, 4_480])
    }

    @Test("two configs with identical fields are equal; differing fields are not")
    func equatable() {
        let a = SttEngineConfig()
        let b = SttEngineConfig()
        #expect(a == b)

        var c = SttEngineConfig()
        c.chunkMs = 1_120
        #expect(a != c)
    }
}

@Suite("SttEngineState")
struct SttEngineStateTests {
    @Test("each case is equal only to itself")
    func equatable() {
        #expect(SttEngineState.idle == .idle)
        #expect(SttEngineState.preparing == .preparing)
        #expect(SttEngineState.ready == .ready)
        #expect(SttEngineState.stopped == .stopped)

        #expect(SttEngineState.idle != .preparing)
        #expect(SttEngineState.preparing != .ready)
        #expect(SttEngineState.ready != .stopped)
        #expect(SttEngineState.stopped != .idle)
    }
}

@Suite("SttEngineError")
struct SttEngineErrorTests {
    @Test("errorDescription is non-empty and human-readable for every case")
    func descriptionsAreNonEmpty() throws {
        let cases: [SttEngineError] = [
            .modelPreparationFailed("download failed"),
            .recognizerCreationFailed("init failed"),
            .unsupportedAudioFormat,
            .transcriptionFailed("transcription failed")
        ]

        for error in cases {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
        }
    }

    @Test("errorDescription interpolates the associated message verbatim")
    func descriptionInterpolatesAssociatedValues() throws {
        let preparationFailed = SttEngineError.modelPreparationFailed("network unreachable")
        #expect(try #require(preparationFailed.errorDescription).contains("network unreachable"))

        let creationFailed = SttEngineError.recognizerCreationFailed("loadFromShared threw")
        #expect(try #require(creationFailed.errorDescription).contains("loadFromShared threw"))

        let transcriptionFailed = SttEngineError.transcriptionFailed("processChunk threw")
        #expect(try #require(transcriptionFailed.errorDescription).contains("processChunk threw"))
    }

    @Test("equatable distinguishes cases and associated values")
    func equatable() {
        #expect(SttEngineError.unsupportedAudioFormat == .unsupportedAudioFormat)
        #expect(SttEngineError.unsupportedAudioFormat != .transcriptionFailed("x"))

        #expect(SttEngineError.modelPreparationFailed("a") == .modelPreparationFailed("a"))
        #expect(SttEngineError.modelPreparationFailed("a") != .modelPreparationFailed("b"))

        #expect(SttEngineError.transcriptionFailed("x") == .transcriptionFailed("x"))
        #expect(SttEngineError.transcriptionFailed("x") != .transcriptionFailed("y"))
    }
}

@Suite("SttFinalizedSegment")
struct SttFinalizedSegmentTests {
    @Test("equatable compares all fields")
    func equatable() {
        let a = SttFinalizedSegment(startMs: 0, endMs: 1_000, text: "hello", confidence: 1.0)
        let b = SttFinalizedSegment(startMs: 0, endMs: 1_000, text: "hello", confidence: 1.0)
        #expect(a == b)

        let differentText = SttFinalizedSegment(startMs: 0, endMs: 1_000, text: "bye", confidence: 1.0)
        #expect(a != differentText)

        let differentTiming = SttFinalizedSegment(startMs: 100, endMs: 1_000, text: "hello", confidence: 1.0)
        #expect(a != differentTiming)
    }
}

@Suite("SttConfirmedWindow")
struct SttConfirmedWindowTests {
    @Test("equatable compares pieces, samples, elapsed bounds, and truncated")
    func equatable() {
        let piece = SttFinalizedSegment(startMs: 0, endMs: 1_000, text: "hello", confidence: 1.0)
        let a = SttConfirmedWindow(pieces: [piece], samples: [1, 2], startElapsed: 0, endElapsed: 1, truncated: false)
        let b = SttConfirmedWindow(pieces: [piece], samples: [1, 2], startElapsed: 0, endElapsed: 1, truncated: false)
        #expect(a == b)

        var differentPieces = a
        differentPieces.pieces = []
        #expect(a != differentPieces)

        var differentSamples = a
        differentSamples.samples = [3, 4]
        #expect(a != differentSamples)

        var differentTruncated = a
        differentTruncated.truncated = true
        #expect(a != differentTruncated)
    }
}

@Suite("SttModelDownloadProgress")
struct SttModelDownloadProgressTests {
    @Test("equatable compares stage and fractionCompleted")
    func equatable() {
        let a = SttModelDownloadProgress(stage: .downloading, fractionCompleted: 0.5)
        let b = SttModelDownloadProgress(stage: .downloading, fractionCompleted: 0.5)
        #expect(a == b)

        let differentStage = SttModelDownloadProgress(stage: .installing, fractionCompleted: 0.5)
        #expect(a != differentStage)

        let differentFraction = SttModelDownloadProgress(stage: .downloading, fractionCompleted: 1.0)
        #expect(a != differentFraction)
    }
}

@Suite("SttVolatileTranscript")
struct SttVolatileTranscriptTests {
    @Test("equatable compares source, text and confirming")
    func equatable() {
        let a = SttVolatileTranscript(source: .mic, text: "こんにち")
        let b = SttVolatileTranscript(source: .mic, text: "こんにち")
        #expect(a == b)

        let differentSource = SttVolatileTranscript(source: .system, text: "こんにち")
        #expect(a != differentSource)

        let differentText = SttVolatileTranscript(source: .mic, text: "こんにちは")
        #expect(a != differentText)

        let differentConfirming = SttVolatileTranscript(source: .mic, text: "こんにち", confirming: "はい。")
        #expect(a != differentConfirming)

        let empty = SttVolatileTranscript(source: .mic, text: "")
        #expect(empty.text.isEmpty)
        // Defaulted so every existing construction site keeps meaning "nothing was confirmed here".
        #expect(empty.confirming.isEmpty)
    }
}

@Suite("SttVolatileUpdate")
struct SttVolatileUpdateTests {
    @Test("both halves default to empty and compare independently")
    func equatable() {
        #expect(SttVolatileUpdate() == SttVolatileUpdate(text: "", confirming: ""))

        let pending = SttVolatileUpdate(text: "こんにち")
        #expect(pending.confirming.isEmpty)
        #expect(pending != SttVolatileUpdate(text: "こんにち", confirming: "はい。"))
        #expect(SttVolatileUpdate(text: "", confirming: "はい。") != SttVolatileUpdate(text: "はい。", confirming: ""))
    }
}
