import Foundation
import Qwen3ASR

// Runs the evaluation clips through Qwen3-ASR (MLX) and writes one hypothesis per clip, the same
// shape as the in-repo harnesses in KikimiTests. Kept as a separate package because Qwen3ASR
// cannot be linked into a test bundle (see Package.swift).
//
// This is *not* Kikimi's `Qwen3BatchDecoder`: it calls the model directly, without the 30s
// low-energy split and CJK join. For clips at or under 30s -- which is what make_clips.py
// produces -- the two are equivalent, since the split is a no-op below the threshold.

struct Clip: Decodable {
    let clipID: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case clipID = "clip_id"
        case source
    }
}

struct Manifest: Decodable {
    let clips: [Clip]
}

func loadWav(_ path: String) throws -> [Float] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let range = data.range(of: Data("data".utf8)) else {
        throw NSError(domain: "probe", code: 1)
    }
    let payload = data.subdata(in: (range.upperBound + 4)..<data.count)
    var samples = [Float]()
    samples.reserveCapacity(payload.count / 2)
    payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for v in raw.bindMemory(to: Int16.self) {
            samples.append(Float(Int16(littleEndian: v)) / 32_768.0)
        }
    }
    return samples
}

let env = ProcessInfo.processInfo.environment
let rootPath = env["KIKIMI_ASR_EVAL_DIR"] ?? "~/.local/state/kikimi/asr-eval"
let root = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath)
let limit = Int(env["PROBE_LIMIT"] ?? "") ?? Int.max

let manifest = try JSONDecoder().decode(
    Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
let outName = env["QWEN3_OUT"] ?? "qwen3_swift_mlx"
let outDir = root.appendingPathComponent("hyp/\(outName)")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Backend is selected by env so the CoreML and MLX conversions can be compared on the
// same clips: the CoreML one measurably loses accuracy (AWS -> "ダブルス"), which is the
// whole reason this probe exists.
let modelId = env["QWEN3_MODEL_ID"] ?? Qwen3ASRModel.defaultModelId
print("loading MLX Qwen3-ASR \(modelId) (downloads on first run)...")
let loadStart = Date()
// No progressHandler: the callback is invoked off the main actor, and a closure written in
// top-level code inherits @MainActor isolation, which trips
// `dispatch_assert_queue` inside swift_task_checkIsolated.
let model = try await Qwen3ASRModel.fromPretrained(modelId: modelId)
print("ready in \(String(format: "%.1f", -loadStart.timeIntervalSinceNow))s")

// Discarded warm-up decode, matching the other harnesses.
if let warm = manifest.clips.first {
    _ = model.transcribe(
        audio: try loadWav(root.appendingPathComponent("clips/\(warm.clipID).wav").path),
        language: "Japanese")
}

var audioSeconds = 0.0
var decodeSeconds = 0.0
for clip in manifest.clips.prefix(limit) {
    let samples = try loadWav(root.appendingPathComponent("clips/\(clip.clipID).wav").path)
    let start = Date()
    let text = model.transcribe(audio: samples, language: "Japanese")
    let elapsed = -start.timeIntervalSinceNow
    audioSeconds += Double(samples.count) / 16_000.0
    decodeSeconds += elapsed
    try text.write(
        to: outDir.appendingPathComponent("\(clip.clipID).txt"),
        atomically: true,
        encoding: String.Encoding.utf8)
    print("\(clip.clipID) [\(clip.source)] \(String(format: "%.2f", elapsed))s: \(text.prefix(90))")
}

let rtf = audioSeconds > 0 ? decodeSeconds / audioSeconds : 0
let summary = """
    model: \(outName)
    clips: \(min(limit, manifest.clips.count))
    audio_seconds: \(String(format: "%.1f", audioSeconds))
    decode_seconds: \(String(format: "%.1f", decodeSeconds))
    rtf: \(String(format: "%.4f", rtf))
    """
print("SUMMARY\n\(summary)")
try summary.write(
    to: outDir.appendingPathComponent("_timing.txt"),
    atomically: true,
    encoding: String.Encoding.utf8)
