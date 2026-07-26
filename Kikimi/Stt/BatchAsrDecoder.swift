import FluidAudio
import Foundation
import os

// MARK: - SttBatchDecoding

/// `TranscriptPipeline`'s seam for the two-pass window re-decode
/// (`docs/design/33-meeting-two-pass-decode.md` §3.1/§3.3) -- same DI convention as
/// `DictationBatchTranscribing` (design 31 §3.1): tests inject a fake that never touches FluidAudio.
/// `BatchAsrDecoder` conforms below.
protocol SttBatchDecoding: Sendable {
    func transcribe(samples: [Float]) async throws -> String
}

// MARK: - BatchAsrDecoder

/// One warm Parakeet batch (full-context) decoder shared by every two-pass consumer in the process
/// (`docs/design/33-meeting-two-pass-decode.md` MT1/MT7). Promoted from
/// `docs/design/31-dictation-two-pass-decode.md` TP1's dictation-only `DictationBatchTranscriber`
/// into a feature-agnostic shared component so the meeting pipeline and dictation can both use it
/// (MT1). All `transcribe` calls are serialized by actor isolation, which doubles as the ANE
/// arbitration between the meeting's two sources and dictation key-up decodes (MT5).
actor BatchAsrDecoder: SttBatchDecoding {
    private let manager: AsrManager
    private let decoderLayers: Int

    init(manager: AsrManager, decoderLayers: Int) {
        self.manager = manager
        self.decoderLayers = decoderLayers
    }

    /// BCP-47 primary subtag rule moved here verbatim from
    /// `DictationBatchTranscriber.resolveModelVersion` (design 31 TP1, design 33 MT1): maps the
    /// *resolved* language (e.g. `stt.language`/dictation's resolved language, never the raw
    /// `"auto"`-permitting config field alone) to a batch model variant by BCP-47 primary subtag --
    /// `"ja"`/`"ja-JP"`/`"ja_JP"` (case-insensitive) -> `.tdtJa` (the Japanese-only model the
    /// word-drop fix was validated on), anything else (including `"auto"`, which `.v3`'s
    /// multilingual model can self-identify) -> `.v3`. An exact `== "ja"` match would silently send
    /// the default configuration (effective `"ja-JP"`) to `.v3` and disable the fix for exactly the
    /// users it was built for.
    static func resolveModelVersion(language: String) -> AsrModelVersion {
        let primarySubtag = language.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
        return primarySubtag == "ja" ? .tdtJa : .v3
    }

    /// Downloads (first launch only, ~600MB for `.tdtJa`; progress is log-only, mirroring the
    /// streaming side's `FluidAudioSttBackendFactory.makeBackend(config:downloadProgress: nil)`)
    /// and loads the batch model. This is `BatchAsrDecoderPool`'s default `load` (MT7/§3.1); pool
    /// tests inject a fake instead so they never touch FluidAudio's network path.
    static func make(version: AsrModelVersion) async throws -> BatchAsrDecoder {
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(models: models)
        return BatchAsrDecoder(manager: manager, decoderLayers: version.decoderLayers)
    }

    /// Decodes one utterance/window with a fresh `TdtDecoderState` per call -- utterances/windows
    /// are independent, so no decoder context may leak between them (the very failure mode of the
    /// streaming model this feature works around). No `language` hint is passed: `.tdtJa` ignores
    /// it, and `.v3`'s token filter only handles Latin/Cyrillic scripts.
    ///
    /// `samples` longer than `ASRConstants.maxModelSamples` (15s @ 16kHz) are never handed to
    /// `AsrManager.transcribe` in one call: past that length FluidAudio internally reroutes to its
    /// `ChunkProcessor` (~15s windows, 2s overlap, seam token-dedup merge), and that seam merge
    /// drops tokens mid-sentence on Japanese audio (confirmed via `BatchRedecodeReproTests` --
    /// decoding the same audio as independent <=15s windows recovers the dropped text). Instead we
    /// split ourselves at low-energy (near-silence) points via `splitForSingleWindowDecode` and
    /// decode each piece as its own single window with a fresh decoder state, then join. For
    /// `samples.count <= maxModelSamples` this is exactly the previous single-call behavior
    /// (`splitForSingleWindowDecode` returns one range spanning all of `samples`).
    func transcribe(samples: [Float]) async throws -> String {
        let ranges = Self.splitForSingleWindowDecode(samples: samples)
        guard ranges.count > 1 else {
            return try await transcribeSingleWindow(samples)
        }
        var pieceTexts: [String] = []
        pieceTexts.reserveCapacity(ranges.count)
        for range in ranges {
            let pieceText = try await transcribeSingleWindow(Array(samples[range]))
            let trimmed = pieceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            pieceTexts.append(trimmed)
        }
        return Self.joinPieceTexts(pieceTexts)
    }

    /// Joins per-piece texts back into one utterance. An ASCII space separator is only inserted
    /// when *both* boundary characters belong to space-delimited scripts (e.g. Latin): CJK text is
    /// not word-spaced, and FluidAudio's own merge never inserted separators either -- a visible
    /// mid-sentence "  " in pasted Japanese dictation text would be a regression of this split.
    /// `internal` (not `private`) so `BatchAsrDecoderSplitTests` can exercise the boundary rules
    /// without a real model.
    static func joinPieceTexts(_ pieces: [String]) -> String {
        var result = ""
        for piece in pieces {
            guard !result.isEmpty else {
                result = piece
                continue
            }
            if let left = result.last, let right = piece.first, !isCjk(left), !isCjk(right) {
                result += " "
            }
            result += piece
        }
        return result
    }

    /// Whether `character` belongs to a CJK script/punctuation block (no word spacing expected on
    /// either side). Coverage is the blocks realistically emitted by the ja/v3 batch models --
    /// kana, CJK ideographs (incl. extension A), CJK punctuation, and fullwidth forms.
    private static func isCjk(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,  // CJK symbols and punctuation (。、「」 etc.)
             0x3040...0x30FF,  // hiragana + katakana
             0x31F0...0x31FF,  // katakana phonetic extensions
             0x3400...0x4DBF,  // CJK unified ideographs extension A
             0x4E00...0x9FFF,  // CJK unified ideographs
             0xFF00...0xFFEF:  // fullwidth forms (ＡＢ・？！ etc.)
            return true
        default:
            return false
        }
    }

    /// Decodes `samples` (already <= `ASRConstants.maxModelSamples`) in one `AsrManager.transcribe`
    /// call with a fresh decoder state. The pre-split single-window path both `transcribe(samples:)`
    /// branches above funnel through.
    private func transcribeSingleWindow(_ samples: [Float]) async throws -> String {
        var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text
    }

    /// Splits `samples` into single-window-decodable pieces (each `<= ASRConstants.maxModelSamples`)
    /// so `transcribe(samples:)` never triggers FluidAudio's lossy `ChunkProcessor` seam merge (see
    /// `transcribe(samples:)`'s doc comment). Samples already `<= maxModelSamples` (including empty
    /// input) come back as a single range spanning the whole array, unchanged.
    ///
    /// For longer input, repeatedly cuts off a piece from the front: within the search window
    /// `[cursor + searchStartSeconds, cursor + searchEndSeconds]`, it picks the center of whichever
    /// `ASRConstants.samplesPerEncoderFrame`-sized (80ms) frame has the lowest RMS energy --
    /// approximating a pause/silence in speech, which is much less likely to fall mid-word than an
    /// arbitrary fixed-offset cut. Looping stops once the remainder is `<= maxModelSamples`.
    ///
    /// The `[10s, 14.5s]` search window (relative to `maxModelSamples` = 15s) guarantees every piece
    /// this produces satisfies FluidAudio's `ASRConstants.minimumAudioDurationSeconds` (0.3s) floor
    /// without an explicit check: a split only happens while the remainder exceeds 15s, so the
    /// remainder left *after* cutting at up to 14.5s in is always > 15s - 14.5s = 0.5s.
    static func splitForSingleWindowDecode(
        samples: [Float],
        maxWindowSamples: Int = ASRConstants.maxModelSamples,
        frameSize: Int = ASRConstants.samplesPerEncoderFrame,
        searchStartSeconds: Double = 10.0,
        searchEndSeconds: Double = 14.5,
        sampleRate: Int = ASRConstants.sampleRate
    ) -> [Range<Int>] {
        guard samples.count > maxWindowSamples else {
            return [0..<samples.count]
        }

        let searchStartOffset = Int(searchStartSeconds * Double(sampleRate))
        let searchEndOffset = Int(searchEndSeconds * Double(sampleRate))
        // Defaults always satisfy this; the parameters only exist as test seams. A search window
        // that is empty or reaches past `maxWindowSamples` could emit an over-long piece plus an
        // empty tail range (which `transcribe` would then feed to FluidAudio's minimum-length
        // rejection), so fail fast instead.
        precondition(
            searchStartOffset > 0 && searchStartOffset < searchEndOffset && searchEndOffset <= maxWindowSamples,
            "search window must satisfy 0 < start < end <= maxWindowSamples"
        )

        var ranges: [Range<Int>] = []
        var cursor = 0
        while samples.count - cursor > maxWindowSamples {
            let windowStart = cursor + searchStartOffset
            let windowEnd = min(cursor + searchEndOffset, samples.count)
            let splitPoint = lowestEnergySplitPoint(
                in: samples, from: windowStart, to: windowEnd, frameSize: frameSize
            )
            ranges.append(cursor..<splitPoint)
            cursor = splitPoint
        }
        ranges.append(cursor..<samples.count)
        return ranges
    }

    /// Returns the center of the lowest-RMS-energy `frameSize`-sized frame within `[start, end)`.
    /// Returns `end` if the window is empty (unreachable given `splitForSingleWindowDecode`'s
    /// precondition, but keeps this helper total).
    private static func lowestEnergySplitPoint(in samples: [Float], from start: Int, to end: Int, frameSize: Int) -> Int {
        guard end > start else { return end }
        var bestCenter = (start + end) / 2
        var bestEnergy = Double.greatestFiniteMagnitude
        var frameStart = start
        while frameStart < end {
            let frameEnd = min(frameStart + frameSize, end)
            let energy = rootMeanSquare(samples, from: frameStart, to: frameEnd)
            if energy < bestEnergy {
                bestEnergy = energy
                bestCenter = (frameStart + frameEnd) / 2
            }
            frameStart = frameEnd
        }
        return bestCenter
    }

    /// RMS energy of `samples[start..<end]`. `Double` accumulation avoids `Float` precision loss
    /// over frames of hundreds/thousands of samples.
    private static func rootMeanSquare(_ samples: [Float], from start: Int, to end: Int) -> Double {
        guard end > start else { return 0 }
        var sumOfSquares = 0.0
        for index in start..<end {
            let value = Double(samples[index])
            sumOfSquares += value * value
        }
        return (sumOfSquares / Double(end - start)).squareRoot()
    }
}

// MARK: - BatchAsrDecoderLease

/// Release-bearing handle returned by `BatchAsrDecoderPool.acquire` (MT7/MT8). `release()` is
/// idempotent -- the second and later calls are no-ops -- so an unbalanced release (releasing
/// without a successful acquire, or releasing twice) is impossible by construction: callers only
/// ever get a `release()` to call by first acquiring successfully, and calling it more than once
/// costs nothing.
final class BatchAsrDecoderLease: Sendable {
    let decoder: BatchAsrDecoder

    /// Guards `onRelease` so it fires at most once even if `release()` is called from multiple
    /// places (e.g. both a normal teardown path and a `deinit`-adjacent cleanup).
    private let hasReleased = OSAllocatedUnfairLock(initialState: false)
    private let onRelease: @Sendable () -> Void

    init(decoder: BatchAsrDecoder, onRelease: @escaping @Sendable () -> Void) {
        self.decoder = decoder
        self.onRelease = onRelease
    }

    func release() {
        let shouldRelease = hasReleased.withLock { alreadyReleased -> Bool in
            guard !alreadyReleased else { return false }
            alreadyReleased = true
            return true
        }
        guard shouldRelease else { return }
        onRelease()
    }
}

// MARK: - BatchAsrDecoderPool

/// Process-wide refcounted registry of warm `BatchAsrDecoder`s, one per `AsrModelVersion`
/// (`docs/design/33-meeting-two-pass-decode.md` MT7). `acquire` increments the refcount on entry
/// and single-flights the load on the first holder for that version; every later caller (whether
/// joining an in-flight load or acquiring an already-warm decoder) just increments the count. On
/// load failure *or* on the acquiring task being cancelled before it observes success, the refcount
/// is decremented back before throwing, so a failed or cancelled acquire never leaves a count
/// behind. The decoder is freed as soon as the last outstanding lease is released (refcount 0;
/// no deferred/lazy unload, matching design 31 §9's dictation-only cadence).
///
/// This is an instance (not an enum + static state): production code uses `.shared`, while pool
/// tests construct isolated instances with an injected loader -- swift-testing runs suites in
/// parallel, and process-global mutable state would leak between tests.
actor BatchAsrDecoderPool {
    static let shared = BatchAsrDecoderPool()

    /// One version's registry slot. Kept in a linear array (rather than
    /// `[AsrModelVersion: Entry]`) because `AsrModelVersion` (from FluidAudio) does not conform to
    /// `Hashable`, and the cardinality here is tiny (at most the handful of `AsrModelVersion` cases
    /// FluidAudio defines -- in practice at most 2 are ever live at once, MT7's ja/non-ja split).
    private struct Entry {
        let version: AsrModelVersion
        var decoder: BatchAsrDecoder?
        var loadTask: Task<BatchAsrDecoder, Error>?
        var refcount = 0
    }

    /// `load` is injectable so tests never touch FluidAudio's network path; production defaults to
    /// `BatchAsrDecoder.make(version:)`.
    private let load: @Sendable (AsrModelVersion) async throws -> BatchAsrDecoder
    private var entries: [Entry] = []

    init(load: @escaping @Sendable (AsrModelVersion) async throws -> BatchAsrDecoder = BatchAsrDecoder.make(version:)) {
        self.load = load
    }

    /// Acquires a lease on the warm decoder for `version`, loading it (single-flight) if this is
    /// the first outstanding holder. Every call -- first holder, joiner of an in-flight load, or
    /// acquirer of an already-warm decoder -- increments the refcount exactly once.
    func acquire(version: AsrModelVersion) async throws -> BatchAsrDecoderLease {
        let index = indexOrInsert(for: version)
        entries[index].refcount += 1

        if let cachedDecoder = entries[index].decoder {
            return makeLease(version: version, decoder: cachedDecoder)
        }

        let task: Task<BatchAsrDecoder, Error>
        if let inFlight = entries[index].loadTask {
            task = inFlight
        } else {
            let load = self.load
            let newTask = Task { try await load(version) }
            entries[index].loadTask = newTask
            task = newTask
        }

        do {
            let decoder = try await task.value
            if let currentIndex = entries.firstIndex(where: { $0.version == version }) {
                entries[currentIndex].decoder = decoder
                entries[currentIndex].loadTask = nil
            }
            // The acquiring `Task` may have been cancelled while this call was suspended awaiting
            // the (possibly shared) load -- the load itself is not cancelled by that (other holders
            // may still need it, single-flight continues), but this particular acquire must not
            // hand out a lease it no longer represents, and must give back its refcount (MT7/MT8's
            // "cancellation never leaks/negatives the count").
            if Task.isCancelled {
                decrementRefcount(version: version)
                throw CancellationError()
            }
            return makeLease(version: version, decoder: decoder)
        } catch {
            // Clear the now-settled (failed) load `Task` before decrementing so that if another
            // acquirer is still holding the refcount above 0 (e.g. it joined this same single-flight
            // load), the *next* acquire call for this version starts a fresh load instead of joining
            // this dead `Task` and immediately rethrowing the same stale error (MT8: a load failure
            // must let a later acquire retry, not get permanently stuck until refcount happens to
            // reach 0).
            if let currentIndex = entries.firstIndex(where: { $0.version == version }) {
                entries[currentIndex].loadTask = nil
            }
            decrementRefcount(version: version)
            throw error
        }
    }

    /// Test-only peek at a version's live refcount (0 if no entry exists at all). `release()`
    /// reaches this actor through a fire-and-forget `Task` (it must stay synchronous to match
    /// `BatchAsrDecoderLease`'s contract), so pool tests poll this to observe that hop having
    /// landed before asserting on its effect, rather than assuming same-tick consistency. Not
    /// `private`: mirrors `DictationController.isBatchDecoderWarm`'s test-observability convention.
    func refcountForTesting(version: AsrModelVersion) -> Int {
        entries.first(where: { $0.version == version })?.refcount ?? 0
    }

    private func indexOrInsert(for version: AsrModelVersion) -> Int {
        if let existing = entries.firstIndex(where: { $0.version == version }) {
            return existing
        }
        entries.append(Entry(version: version))
        return entries.count - 1
    }

    private func decrementRefcount(version: AsrModelVersion) {
        guard let index = entries.firstIndex(where: { $0.version == version }) else { return }
        entries[index].refcount -= 1
        if entries[index].refcount <= 0 {
            entries.remove(at: index)
        }
    }

    private func makeLease(version: AsrModelVersion, decoder: BatchAsrDecoder) -> BatchAsrDecoderLease {
        BatchAsrDecoderLease(decoder: decoder) { [weak self] in
            guard let self else { return }
            Task { await self.decrementRefcount(version: version) }
        }
    }
}
