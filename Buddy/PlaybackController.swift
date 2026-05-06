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
        // Reuse the playAndRecord session AppDelegate sets at launch — switching
        // to .playback while the recorder's engine has a live mic tap was firing
        // an interruption and stalling the app. AVAudioPlayer plays fine under
        // playAndRecord with .defaultToSpeaker.
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            guard p.play() else {
                stop()
                return
            }
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
    }
}

extension PlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
