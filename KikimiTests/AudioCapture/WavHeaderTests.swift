import Foundation
import Testing

@testable import Kikimi

@Suite("WavHeader")
struct WavHeaderTests {
    @Test("encode() produces exactly 44 bytes")
    func encodeProducesFixedSize() {
        let header = WavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataByteCount: 0)
        #expect(header.encode().count == 44)
    }

    @Test("encode() writes correct RIFF/WAVE/fmt/data layout for mono 16kHz 16-bit")
    func encodeMono16kHz16Bit() {
        let dataByteCount: UInt32 = 3_200 // e.g. 1600 samples * 2 bytes
        let header = WavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataByteCount: dataByteCount)
        let bytes = [UInt8](header.encode())

        #expect(bytes.count == 44)

        // "RIFF"
        #expect(Array(bytes[0..<4]) == Array("RIFF".utf8))
        // RIFF chunk size = 36 + dataByteCount
        #expect(readUInt32LE(bytes, at: 4) == 36 + dataByteCount)
        // "WAVE"
        #expect(Array(bytes[8..<12]) == Array("WAVE".utf8))
        // "fmt "
        #expect(Array(bytes[12..<16]) == Array("fmt ".utf8))
        // fmt chunk size = 16 (PCM)
        #expect(readUInt32LE(bytes, at: 16) == 16)
        // audio format = 1 (PCM)
        #expect(readUInt16LE(bytes, at: 20) == 1)
        // channels
        #expect(readUInt16LE(bytes, at: 22) == 1)
        // sample rate
        #expect(readUInt32LE(bytes, at: 24) == 16_000)
        // byte rate = sampleRate * channels * bitsPerSample / 8
        #expect(readUInt32LE(bytes, at: 28) == 16_000 * 1 * 16 / 8)
        // block align = channels * bitsPerSample / 8
        #expect(readUInt16LE(bytes, at: 32) == 1 * 16 / 8)
        // bits per sample
        #expect(readUInt16LE(bytes, at: 34) == 16)
        // "data"
        #expect(Array(bytes[36..<40]) == Array("data".utf8))
        // data chunk size
        #expect(readUInt32LE(bytes, at: 40) == dataByteCount)
    }

    @Test("encode() reflects stereo channel count and byte rate")
    func encodeStereo() {
        let header = WavHeader(sampleRate: 44_100, channels: 2, bitsPerSample: 16, dataByteCount: 0)
        let bytes = [UInt8](header.encode())

        #expect(readUInt16LE(bytes, at: 22) == 2)
        #expect(readUInt32LE(bytes, at: 24) == 44_100)
        #expect(readUInt32LE(bytes, at: 28) == 44_100 * 2 * 16 / 8)
        #expect(readUInt16LE(bytes, at: 32) == 2 * 16 / 8)
    }

    @Test("two headers with the same fields are equal")
    func equatable() {
        let a = WavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataByteCount: 100)
        let b = WavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataByteCount: 100)
        let c = WavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataByteCount: 200)

        #expect(a == b)
        #expect(a != c)
    }

    @Test("in-progress header (dataByteCount 0) differs from final header only in size fields")
    func inProgressVsFinalHeader() {
        let inProgress = WavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataByteCount: 0)
        let final = WavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataByteCount: 6_400)

        let inProgressBytes = [UInt8](inProgress.encode())
        let finalBytes = [UInt8](final.encode())

        // fmt chunk (bytes 12..<36) is identical regardless of dataByteCount.
        #expect(Array(inProgressBytes[12..<36]) == Array(finalBytes[12..<36]))
        // Only the RIFF size and data size fields differ.
        #expect(readUInt32LE(inProgressBytes, at: 4) != readUInt32LE(finalBytes, at: 4))
        #expect(readUInt32LE(inProgressBytes, at: 40) != readUInt32LE(finalBytes, at: 40))
    }
}

private func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

private func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}
