import CoreML
import FluidAudio
import Foundation
import Testing

@testable import Kikimi

/// Cohere Transcribe arm of the batch-decoder evaluation (`tools/asr-eval/`).
///
/// Kept separate from `AsrEvalHarness` because Cohere is not an `AsrModelVersion`: it is a
/// standalone encoder-decoder pipeline in FluidAudio (`CoherePipeline`) with its own loader,
/// its own 35s audio cap, and an autoregressive decoder. It cannot be reached through
/// `BatchAsrDecoder`, so this arm measures the pipeline directly -- which also means its
/// number answers "what would Cohere give us", not "what does Kikimi give us today".
///
/// The 108-token decode cap is a property of the shipped model (`maxSeqLen`, the KV cache
/// depth), not a tunable: Japanese SentencePiece output for a 30s meeting clip can exceed it,
/// in which case the hypothesis is truncated mid-sentence. That truncation is *not* corrected
/// here -- it is exactly the kind of limit the evaluation exists to expose, and hiding it
/// behind a re-chunk would report an accuracy the product could not reproduce.
///
///     KIKIMI_ASR_EVAL_DIR=~/.local/state/kikimi/asr-eval \
///     swift test --filter AsrEvalCohereHarness
@Suite("ASR eval harness (Cohere)")
struct AsrEvalCohereHarness {
    @Test(
        "decode every eval clip with Cohere Transcribe",
        .enabled(if: ProcessInfo.processInfo.environment["KIKIMI_ASR_EVAL_DIR"] != nil),
        .timeLimit(.minutes(60))
    )
    func decodeClips() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: (env["KIKIMI_ASR_EVAL_DIR"]! as NSString).expandingTildeInPath)
        let modelName = "cohere"

        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let outDir = root.appendingPathComponent("hyp/\(modelName)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Same on-disk layout FluidAudio uses for every other model, so a run here warms the
        // cache the app would use if Cohere were adopted.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let modelsRoot = appSupport.appendingPathComponent("FluidAudio/Models")
        let repo = Repo.cohereTranscribeCoreml
        let modelDir = modelsRoot.appendingPathComponent(repo.folderName)

        if !FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent(ModelNames.CohereTranscribe.encoderCompiledFile).path)
        {
            print("EVAL: downloading \(repo.folderName) (INT8 encoder, ~1.8GB)...")
            try await DownloadUtils.downloadRepo(repo, to: modelsRoot)
        }

        print("EVAL: loading Cohere from \(modelDir.path)...")
        let loadStart = Date()
        let pipeline = CoherePipeline()
        let models = try await CoherePipeline.loadModels(
            encoderDir: modelDir, decoderDir: modelDir, vocabDir: modelDir)
        print("EVAL: model ready in \(String(format: "%.1f", -loadStart.timeIntervalSinceNow))s")

        // Decode one clip and throw the result away before timing anything. The first
        // inference after load pays CoreML's compute-plan specialization -- 87s vs ~9s for
        // the same-sized clip when measured -- which is a one-time cost the meeting pipeline
        // pays at `prepare()`, not per segment. Leaving it in would report an RTF no steady
        // state ever exhibits.
        if let warmup = manifest.clips.first {
            let wav = root.appendingPathComponent("clips/\(warmup.clipID).wav")
            let samples = try WavTestLoader.loadSamples(path: wav.path)
            print("EVAL: warming up on \(warmup.clipID)...")
            _ = try await pipeline.transcribe(audio: samples, models: models, language: .japanese)
        }

        var audioSeconds = 0.0
        var decodeSeconds = 0.0
        var capped = 0
        for clip in manifest.clips {
            let wav = root.appendingPathComponent("clips/\(clip.clipID).wav")
            let samples = try WavTestLoader.loadSamples(path: wav.path)
            let start = Date()
            let result = try await pipeline.transcribe(audio: samples, models: models, language: .japanese)
            let elapsed = -start.timeIntervalSinceNow
            audioSeconds += Double(samples.count) / 16_000.0
            decodeSeconds += elapsed
            // A hypothesis that used every available token almost certainly ran out of room
            // rather than finishing its sentence; counted so the summary can say so.
            if result.tokenIds.count >= CohereAsrConfig.maxSeqLen - 1 { capped += 1 }
            try result.text.write(
                to: outDir.appendingPathComponent("\(clip.clipID).txt"),
                atomically: true,
                encoding: .utf8)
            print(
                "EVAL \(clip.clipID) [\(clip.source)] \(String(format: "%.2f", elapsed))s "
                    + "tok=\(result.tokenIds.count): \(result.text)")
        }

        let rtf = audioSeconds > 0 ? decodeSeconds / audioSeconds : 0
        let summary = """
            model: \(modelName)
            clips: \(manifest.clips.count)
            audio_seconds: \(String(format: "%.1f", audioSeconds))
            decode_seconds: \(String(format: "%.1f", decodeSeconds))
            rtf: \(String(format: "%.4f", rtf))
            token_capped_clips: \(capped)/\(manifest.clips.count)
            """
        print("EVAL SUMMARY\n\(summary)")
        try summary.write(
            to: outDir.appendingPathComponent("_timing.txt"), atomically: true, encoding: .utf8)
    }

    private struct Manifest: Decodable {
        let clips: [Clip]
    }

    private struct Clip: Decodable {
        let clipID: String
        let source: String

        enum CodingKeys: String, CodingKey {
            case clipID = "clip_id"
            case source
        }
    }
}
