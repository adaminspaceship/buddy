import UIKit
import SwiftUI
import AVFoundation
import AppIntents
import os

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let log = Logger(subsystem: "com.trycaret.buddy", category: "AppDelegate")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configureAudioSession()
        if SettingsStore.shared.alwaysOn {
            RecorderController.shared.start()
        }
        BuddyShortcuts.updateAppShortcutParameters()
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleAppActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        return true
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // No .allowBluetoothHFP — including it makes iOS negotiate AirPods
            // over HFP at activation, which yanks them off the user's Mac.
            // Built-in mic is fine; the phone is usually in a pocket anyway.
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true, options: [])
        } catch {
            Self.log.error("Audio session config failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Recover the engine if iOS handed the mic to another app and never sent
    /// us a clean .ended interruption when it finished. Cheap to call: only
    /// re-arms when "always on" is enabled and the engine isn't already live.
    @objc private func handleAppActive() {
        guard SettingsStore.shared.alwaysOn,
              !RecorderController.shared.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        RecorderController.shared.start()
    }

    /// `mediaServicesWereResetNotification` is iOS's "audio land just got
    /// nuked" signal. Tear down and re-arm.
    @objc private func handleMediaServicesReset() {
        Self.log.error("Media services were reset; rebuilding audio stack.")
        RecorderController.shared.stop()
        configureAudioSession()
        if SettingsStore.shared.alwaysOn {
            RecorderController.shared.start()
        }
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView:
            ContentView()
                .environmentObject(RecorderController.shared)
                .environmentObject(SettingsStore.shared)
        )
        self.window = window
        window.makeKeyAndVisible()

        // Handle deep-link launches (buddy://configure?endpoint=...&token=...)
        for ctx in options.urlContexts {
            DeepLinkHandler.handle(ctx.url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for ctx in URLContexts {
            DeepLinkHandler.handle(ctx.url)
        }
    }
}
