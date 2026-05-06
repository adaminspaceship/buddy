import Foundation
import AVFoundation
import Combine

@MainActor
final class PlaybackController: NSObject, ObservableObject {
    static let shared = PlaybackController()

    @Published private(set) var playingURL: URL?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playingURL == url {
            stop()
            return
        }
        play(url)
    }

    func play(_ url: URL) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            playingURL = url
        } catch {
            print("Playback failed: \(error)")
            stop()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
        // Restore record-capable session if recorder is running.
        if RecorderController.shared.isRunning {
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }
}

extension PlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
