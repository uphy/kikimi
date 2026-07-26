import Foundation

/// Byte-level representation of a fixed 44-byte PCM WAV header.
///
/// A pure value type with no file I/O. Layer-1 tests (see `docs/design/01-audio-capture.md`
/// section 10) exercise this type directly to verify "sample size -> correct 44-byte header"
/// without touching the filesystem.
struct WavHeader: Equatable {
    var sampleRate: UInt32
    var channels: UInt16
    var bitsPerSample: UInt16

    /// Total byte count of the sample data written so far (i.e. the `data` chunk size).
    /// Holds a provisional value while recording is in progress, and the final value once
    /// `WavFileWriter.close()` has run (see section 8/10 of the design doc for the
    /// "in-progress header" vs. "final header" comparison).
    var dataByteCount: UInt32

    /// Generates the 44-byte header with the RIFF/data chunk sizes filled in.
    /// Pure function, no I/O.
    func encode() -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let riffChunkSize = 36 + dataByteCount

        var data = Data(capacity: 44)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(riffChunkSize)
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16)) // fmt chunk size (PCM)
        data.appendLittleEndian(UInt16(1)) // audio format: PCM
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)

        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataByteCount)

        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
