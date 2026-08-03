import FluidAudio
import Foundation
import Testing

@testable import Kikimi

/// Runs the evaluation clips (`tools/asr-eval/make_clips.py`) through Kikimi's **real**
/// batch decode path and writes one hypothesis file per clip.
///
/// This deliberately goes through `BatchAsrDecoder.transcribe` rather than calling
/// `AsrManager` directly: the thing being evaluated is what the product would ship, which
/// includes the low-energy split for windows over 15s (`splitForSingleWindowDecode`) and
/// the CJK-aware join. Measuring a bare `AsrManager` would produce a number no user ever
/// experiences.
///
/// Gated on `KIKIMI_ASR_EVAL_DIR` so it never runs in a normal sweep -- it downloads and
/// loads ~600MB of model weights and takes minutes.
///
///     KIKIMI_ASR_EVAL_DIR=~/.local/state/kikimi/asr-eval \
///     KIKIMI_ASR_EVAL_MODEL=tdtja \
///     swift test --filter AsrEvalHarness
@Suite("ASR eval harness")
struct AsrEvalHarness {
    @Test(
        "decode every eval clip with a FluidAudio batch model",
        .enabled(if: ProcessInfo.processInfo.environment["KIKIMI_ASR_EVAL_DIR"] != nil),
        .timeLimit(.minutes(30))
    )
    func decodeClips() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: (env["KIKIMI_ASR_EVAL_DIR"]! as NSString).expandingTildeInPath)
        let modelName = env["KIKIMI_ASR_EVAL_MODEL"] ?? "tdtja"
        let version: AsrModelVersion
        switch modelName {
        case "tdtja": version = .tdtJa
        case "parakeet_v3": version = .v3
        case "parakeet_v2": version = .v2
        case "tdtctc110m": version = .tdtCtc110m
        default:
            Issue.record("unknown KIKIMI_ASR_EVAL_MODEL: \(modelName)")
            return
        }

        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: manifestURL))
        let outDir = root.appendingPathComponent("hyp/\(modelName)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        print("EVAL: loading \(modelName) (\(version))...")
        let loadStart = Date()
        let decoder = try await BatchAsrDecoder.make(version: version)
        print("EVAL: model ready in \(String(format: "%.1f", -loadStart.timeIntervalSinceNow))s")

        // Discarded warm-up decode: the first inference after load pays CoreML's compute-plan
        // specialization, a one-time cost the meeting pipeline pays at `prepare()` rather than
        // per confirmed segment. Kept symmetric with the Cohere arm so the RTFs are comparable.
        if let warmup = manifest.clips.first {
            let wav = root.appendingPathComponent("clips/\(warmup.clipID).wav")
            _ = try await decoder.transcribe(samples: WavTestLoader.loadSamples(path: wav.path))
        }

        var audioSeconds = 0.0
        var decodeSeconds = 0.0
        for clip in manifest.clips {
            let wav = root.appendingPathComponent("clips/\(clip.clipID).wav")
            let samples = try WavTestLoader.loadSamples(path: wav.path)
            let start = Date()
            let text = try await decoder.transcribe(samples: samples)
            let elapsed = -start.timeIntervalSinceNow
            audioSeconds += Double(samples.count) / 16_000.0
            decodeSeconds += elapsed
            try text.write(
                to: outDir.appendingPathComponent("\(clip.clipID).txt"),
                atomically: true,
                encoding: .utf8)
            print("EVAL \(clip.clipID) [\(clip.source)] \(String(format: "%.2f", elapsed))s: \(text)")
        }

        // RTF is reported alongside CER because the meeting pipeline re-decodes on every
        // segment confirmation: a model that wins on accuracy but decodes slower than
        // real time would stall confirmed text behind the live stream.
        let rtf = audioSeconds > 0 ? decodeSeconds / audioSeconds : 0
        let summary = """
            model: \(modelName)
            clips: \(manifest.clips.count)
            audio_seconds: \(String(format: "%.1f", audioSeconds))
            decode_seconds: \(String(format: "%.1f", decodeSeconds))
            rtf: \(String(format: "%.4f", rtf))
            """
        print("EVAL SUMMARY\n\(summary)")
        try summary.write(
            to: outDir.appendingPathComponent("_timing.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - manifest.json (written by tools/asr-eval/make_clips.py)

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
