import Foundation
import Testing

@testable import Kikimi

// Temporary repro harness: decodes a real dictation-history WAV through the exact
// batch path (`BatchAsrDecoder`) to investigate tail/middle truncation.
// Gated on KIKIMI_REPRO_WAV so it never runs in normal test sweeps.
@Suite("Batch re-decode repro")
struct BatchRedecodeReproTests {
    @Test(
        "re-decode a dictation history WAV with the tdtJa batch model",
        .enabled(if: ProcessInfo.processInfo.environment["KIKIMI_REPRO_WAV"] != nil)
    )
    func redecodeWav() async throws {
        let path = ProcessInfo.processInfo.environment["KIKIMI_REPRO_WAV"]!
        let samples = try Self.loadWavSamples(path: path)
        print("REPRO: loaded \(samples.count) samples (\(Double(samples.count) / 16_000.0)s)")

        let decoder = try await BatchAsrDecoder.make(version: .tdtJa)
        let full = try await decoder.transcribe(samples: samples)
        print("REPRO FULL: \(full)")

        // Also decode the tail 10s alone, to check whether the missing ending is
        // decodable at all when it doesn't sit at a chunk boundary.
        let tail = Array(samples.suffix(10 * 16_000))
        let tailText = try await decoder.transcribe(samples: tail)
        print("REPRO TAIL10S: \(tailText)")

        // And the middle 8..20s region that covers the dropped middle sentence.
        let mid = Array(samples.dropFirst(8 * 16_000).prefix(12 * 16_000))
        let midText = try await decoder.transcribe(samples: mid)
        print("REPRO MID 8-20S: \(midText)")
    }

    /// Minimal 16kHz mono 16-bit PCM WAV reader (matches WavFileWriter's output format).
    private static func loadWavSamples(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // Find the "data" chunk rather than assuming a 44-byte header.
        let marker = Data("data".utf8)
        guard let range = data.range(of: marker) else {
            throw NSError(domain: "repro", code: 1, userInfo: [NSLocalizedDescriptionKey: "no data chunk"])
        }
        let payloadStart = range.upperBound + 4  // skip chunk size field
        let payload = data.subdata(in: payloadStart..<data.count)
        var samples = [Float]()
        samples.reserveCapacity(payload.count / 2)
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let int16s = raw.bindMemory(to: Int16.self)
            for value in int16s {
                samples.append(Float(Int16(littleEndian: value)) / 32_768.0)
            }
        }
        return samples
    }
}
