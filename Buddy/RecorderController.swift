import Foundation
import AVFoundation
import Combine
import UIKit
import os

/// Owns the AVAudioEngine, the rolling buffer, and exposes a single shared
/// instance so an App Intent (Action Button / Back Tap / Shortcuts) can grab
/// the last N seconds without launching the UI.
@MainActor
final class RecorderController: ObservableObject {
    static let shared = RecorderController()

    private let log = Logger(subsystem: "com.trycaret.buddy", category: "Recorder")
    private let engine = AVAudioEngine()
    private var ringBuffer: RollingAudioBuffer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    @Published private(set) var isRunning = false
    @Published private(set) var lastCapture: CaptureRecord?
    @Published private(set) var recentCaptures: [CaptureRecord] = []

    /// User-configurable buffer length. Reads SettingsStore at start time.
    var windowSeconds: Double {
        Double(SettingsStore.shared.bufferSeconds)
    }

    private init() {
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    func start() {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            log.error("Input format has zero sample rate; aborting start.")
            return
        }
        let ring = RollingAudioBuffer(sampleRate: format.sampleRate,
                                      windowSeconds: windowSeconds)
        ringBuffer = ring

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak ring] buffer, _ in
            ring?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            log.info("Engine started @ \(format.sampleRate, privacy: .public) Hz, \(self.windowSeconds, privacy: .public)s window")
        } catch {
            log.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        ringBuffer = nil
        isRunning = false
    }

    /// The App Intent target. Snapshots the ring, writes a WAV, kicks off the upload.
    @discardableResult
    func captureLast30Seconds(reason: String = "intent") async -> CaptureRecord? {
        if !isRunning { start() }
        guard let ring = ringBuffer else {
            log.error("Capture requested but ring buffer is nil")
            return nil
        }
        if ring.snapshot().isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        beginBackgroundTask()
        defer { endBackgroundTask() }

        let pcm = ring.snapshot()
        guard !pcm.isEmpty else {
            log.error("Snapshot was empty")
            return nil
        }
        let url = makeClipURL()
        do {
            try WAVWriter.write(samples: pcm,
                                sampleRate: ring.sampleRate,
                                to: url)
        } catch {
            log.error("WAV write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let record = CaptureRecord(id: UUID(),
                                   fileURL: url,
                                   capturedAt: Date(),
                                   durationSeconds: Double(pcm.count) / ring.sampleRate,
                                   reason: reason,
                                   uploadState: .pending)
        await MainActor.run {
            self.lastCapture = record
            self.recentCaptures.insert(record, at: 0)
            if self.recentCaptures.count > 50 { self.recentCaptures.removeLast() }
        }

        Uploader.shared.enqueue(record) { [weak self] updated in
            Task { @MainActor in
                guard let self else { return }
                self.log.info("🟡 recorder got completion for \(updated.id.uuidString, privacy: .public): \(String(describing: updated.uploadState), privacy: .public)")
                if self.lastCapture?.id == updated.id { self.lastCapture = updated }
                if let idx = self.recentCaptures.firstIndex(where: { $0.id == updated.id }) {
                    self.recentCaptures[idx] = updated
                    self.log.info("🟡 updated recentCaptures[\(idx, privacy: .public)] in-place")
                } else {
                    self.log.warning("🟡 no matching record in recentCaptures for \(updated.id.uuidString, privacy: .public)")
                }
            }
        }
        return record
    }

    // MARK: - Plumbing

    private func makeClipURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("clip-\(stamp).wav")
    }

    private func beginBackgroundTask() {
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "buddy-capture-upload") { [weak self] in
            self?.endBackgroundTask()
        }
    }
    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            log.info("Audio session interrupted; engine paused.")
            // Don't tear the engine down — iOS does that for us. We just stop
            // tracking it as "running" so the next attempt rebuilds cleanly.
            isRunning = false
        case .ended:
            // Always re-arm if "always on" — don't gate on shouldResume option,
            // some apps (Camera, Voice Memos) finish without setting it.
            try? AVAudioSession.sharedInstance().setActive(true, options: [])
            if SettingsStore.shared.alwaysOn {
                stop()
                start()
            }
        @unknown default: break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        // Input device change (e.g. AirPods) requires a fresh tap with the new format.
        if isRunning {
            stop()
            start()
        }
    }
}

struct CaptureRecord: Identifiable, Equatable {
    enum UploadState: Equatable {
        case pending
        case transcribing
        case uploading
        case uploaded(transcript: String?)
        case failed(message: String)
    }
    let id: UUID
    let fileURL: URL
    let capturedAt: Date
    let durationSeconds: Double
    let reason: String
    var uploadState: UploadState
}
