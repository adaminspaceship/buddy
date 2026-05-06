import Foundation

enum WAVWriter {
    /// Writes 16-bit mono PCM to a RIFF/WAV file. Cheap, no AVFoundation roundtrip.
    static func write(samples: [Int16], sampleRate: Double, to url: URL) throws {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        let chunkSize = 36 + dataSize

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.appendLE(chunkSize)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.appendLE(UInt32(16))                 // PCM fmt chunk size
        data.appendLE(UInt16(1))                  // PCM format
        data.appendLE(channels)
        data.appendLE(UInt32(sampleRate))
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.append("data".data(using: .ascii)!)
        data.appendLE(dataSize)
        samples.withUnsafeBufferPointer { buf in
            data.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
        try data.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func append(_ buf: UnsafeBufferPointer<Int16>) {
        buf.withMemoryRebound(to: UInt8.self) { bytes in
            append(bytes.baseAddress!, count: buf.count * MemoryLayout<Int16>.size)
        }
    }
}
