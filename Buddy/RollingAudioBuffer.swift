import Foundation
import AVFoundation
import os

/// Lock-protected ring buffer of recent PCM frames. Fixed window in seconds.
/// Stores Int16 mono samples at the input sample rate so the snapshot can be
/// written to disk as a CAF/WAV without re-encoding.
final class RollingAudioBuffer {
    private let log = Logger(subsystem: "com.trycaret.audiodashcam", category: "RingBuffer")
    private let lock = NSLock()
    private var samples: [Int16]
    private var writeIndex: Int = 0
    private var filled: Int = 0

    let sampleRate: Double
    let windowSeconds: Double
    let capacity: Int

    init(sampleRate: Double, windowSeconds: Double) {
        self.sampleRate = sampleRate
        self.windowSeconds = windowSeconds
        self.capacity = Int(sampleRate * windowSeconds)
        self.samples = [Int16](repeating: 0, count: capacity)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.int16ChannelData else {
            // Fall back to float conversion if the engine handed us float frames.
            appendFloat(buffer)
            return
        }
        let frameCount = Int(buffer.frameLength)
        let ptr = channelData[0]
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<frameCount {
            samples[writeIndex] = ptr[i]
            writeIndex = (writeIndex + 1) % capacity
        }
        filled = min(capacity, filled + frameCount)
    }

    private func appendFloat(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let ptr = floatData[0]
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, ptr[i]))
            samples[writeIndex] = Int16(clamped * Float(Int16.max))
            writeIndex = (writeIndex + 1) % capacity
        }
        filled = min(capacity, filled + frameCount)
    }

    /// Returns the most recent `windowSeconds` worth of samples in chronological order.
    func snapshot() -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        guard filled > 0 else { return [] }
        if filled < capacity {
            return Array(samples[0..<filled])
        }
        let tail = samples[writeIndex..<capacity]
        let head = samples[0..<writeIndex]
        return Array(tail) + Array(head)
    }
}
