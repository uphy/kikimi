import Foundation

/// Minimal 16 kHz mono 16-bit PCM WAV reader, matching `WavFileWriter`'s output format
/// (`Kikimi/AudioCapture/`) -- which is also the format of every recorded session's
/// `audio/*.wav` and of the evaluation clips cut from them by `tools/asr-eval/make_clips.py`.
///
/// Used by the harnesses that feed real recorded audio through the real batch decode path
/// (`BatchRedecodeReproTests`, `AsrEvalHarness`). Both are env-gated and never run in a
/// normal test sweep, but they must read the same bytes the app wrote -- no resampling, no
/// AVFoundation conversion in between -- or the thing under investigation is the reader.
enum WavTestLoader {
    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
    }

    /// Reads the `data` chunk and converts to the `[Float]` in [-1, 1) that `AsrManager` expects.
    ///
    /// The `data` chunk is located by scanning rather than by assuming a 44-byte header: writers
    /// are free to emit `LIST`/`fact` chunks before it, and a fixed offset would silently decode
    /// header bytes as audio.
    static func loadSamples(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let range = data.range(of: Data("data".utf8)) else {
            throw Error(description: "\(path): no data chunk")
        }
        let payloadStart = range.upperBound + 4  // skip the chunk size field
        guard payloadStart <= data.count else {
            throw Error(description: "\(path): truncated data chunk")
        }
        let payload = data.subdata(in: payloadStart..<data.count)
        var samples = [Float]()
        samples.reserveCapacity(payload.count / 2)
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for value in raw.bindMemory(to: Int16.self) {
                samples.append(Float(Int16(littleEndian: value)) / 32_768.0)
            }
        }
        return samples
    }
}
