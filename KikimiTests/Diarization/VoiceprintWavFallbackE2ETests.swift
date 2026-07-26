import Foundation
import Testing

@testable import Kikimi

// MARK: - VoiceprintWavFallbackE2ETests

/// Opt-in, environment-gated end-to-end test for the WAV voiceprint fallback
/// (`docs/design/13-speaker-diarization.md` section 4.4's 実装時の追記): runs the REAL
/// `VoiceprintExtractor` (CoreML WeSpeaker, auto-downloading `wespeaker_v2`/`pyannote_segmentation`
/// on first use) against a REAL session folder's `diarization.jsonl` + `audio/system_NNN.wav`, then
/// registers the result into a throwaway `VoiceprintStore`. This is the layer-2 integration check
/// design section 11 asks for ("リネーム操作 → グローバル DB への登録") minus the UI click, which AX
/// scripting cannot drive in this environment (nonactivating-panel popovers never present via
/// AXPress; see memory `kikimi-verify-env-limits`).
///
/// Skipped unless `KIKIMI_VOICEPRINT_E2E_SESSION` points at a session directory containing
/// `meta.json`, `diarization.jsonl`, and `audio/system_000.wav`, so normal `swift test` runs stay
/// hermetic and offline. Run manually with e.g.:
///
///     KIKIMI_VOICEPRINT_E2E_SESSION=~/.local/state/kikimi/sessions/<id> \
///         swift test --filter VoiceprintWavFallbackE2E
@Suite struct VoiceprintWavFallbackE2ETests {
    private static let sessionPath = ProcessInfo.processInfo.environment["KIKIMI_VOICEPRINT_E2E_SESSION"]

    @Test(
        "real WAV -> real WeSpeaker extraction -> VoiceprintStore registration round-trips",
        .enabled(if: sessionPath != nil)
    )
    func extractsAndRegistersFromRealSessionAudio() async throws {
        let sessionDir = URL(
            fileURLWithPath: (Self.sessionPath! as NSString).expandingTildeInPath,
            isDirectory: true
        )
        let metaData = try Data(contentsOf: sessionDir.appendingPathComponent("meta.json"))
        let meta = try SessionJSONCoding.makeDecoder().decode(SessionMeta.self, from: metaData)
        let handle = SessionHandle(directoryURL: sessionDir, meta: meta)

        // Real extractor: lazily downloads/loads the WeSpeaker CoreML models on first call.
        let fallback = VoiceprintWavFallbackExtractor(sessionHandle: handle)

        let embedding = try await fallback.extractEmbedding(forSlot: "spk_1")
        let unwrapped = try #require(embedding, "spk_1 should have enough attributed speech in this session")
        #expect(unwrapped.count == 256)

        // VoiceprintExtractor promises an L2-normalized vector (design section 2.2).
        let norm = unwrapped.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1.0) < 0.01, "embedding should be L2-normalized (norm=\(norm))")

        // Register into a throwaway store -- never the real ~/.local/state/kikimi/voiceprints.json.
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceprintWavFallbackE2E-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("voiceprints.json")
        let store = VoiceprintStore(fileURL: storeURL)
        let registered = try await store.registerSpeaker(name: "e2e-speaker", embedding: unwrapped)
        #expect(registered.name == "e2e-speaker")

        // The persisted file must decode back to the same speaker with the same embedding.
        let persisted = try SessionJSONCoding.makeDecoder().decode(
            VoiceprintDatabase.self,
            from: Data(contentsOf: storeURL)
        )
        #expect(persisted.speakers.count == 1)
        #expect(persisted.speakers.first?.embedding == unwrapped)
    }
}
