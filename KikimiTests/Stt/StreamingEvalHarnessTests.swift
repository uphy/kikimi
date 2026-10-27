import Foundation
import Testing

@testable import Kikimi

// Evaluation harness for FluidAudio upgrades: feeds every dictation-history WAV under
// KIKIMI_STREAM_EVAL_DIR through the live streaming path (`DictationTranscriber` +
// Nemotron) exactly as a key-down/key-up would, and writes one JSON line per entry to
// KIKIMI_STREAM_EVAL_OUT. Gated on both variables so it never runs in normal test sweeps.
//
//   KIKIMI_STREAM_EVAL_DIR=~/.local/state/kikimi/dictation/history \
//   KIKIMI_STREAM_EVAL_OUT=/tmp/stream-eval.jsonl \
//   mise run test -- --filter StreamingEvalHarness
@Suite("Streaming eval harness")
struct StreamingEvalHarnessTests {
    private static let environment = ProcessInfo.processInfo.environment

    @Test(
        "decode dictation history WAVs with the streaming backend",
        .enabled(if: environment["KIKIMI_STREAM_EVAL_DIR"] != nil && environment["KIKIMI_STREAM_EVAL_OUT"] != nil)
    )
    func decodeHistory() async throws {
        let directory = URL(fileURLWithPath: Self.environment["KIKIMI_STREAM_EVAL_DIR"]!)
        let output = URL(fileURLWithPath: Self.environment["KIKIMI_STREAM_EVAL_OUT"]!)
        let limit = Int(Self.environment["KIKIMI_STREAM_EVAL_LIMIT"] ?? "") ?? 40

        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("audio.wav").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)

        let transcriber = try await DictationTranscriber.make(config: SttEngineConfig())
        var lines: [String] = []
        for entry in entries {
            let samples = try WavTestLoader.loadSamples(path: entry.appendingPathComponent("audio.wav").path)
            let started = Date()
            await transcriber.beginUtterance()
            // 100 ms buffers, like the live microphone tap.
            for start in stride(from: 0, to: samples.count, by: 1_600) {
                try await transcriber.feed(samples: Array(samples[start..<min(start + 1_600, samples.count)]))
            }
            let text = try await transcriber.finishUtterance()
            let record: [String: Any] = [
                "id": entry.lastPathComponent,
                "seconds": Double(samples.count) / 16_000,
                "decode_seconds": Date().timeIntervalSince(started),
                "streaming_text": text
            ]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            lines.append(String(decoding: data, as: UTF8.self))
            print("STREAM-EVAL \(entry.lastPathComponent): \(text)")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
    }
}
