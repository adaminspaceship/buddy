import SwiftUI

@main
struct BuddyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(RecorderController.shared)
                .environmentObject(SettingsStore.shared)
                .onOpenURL { url in
                    DeepLinkHandler.handle(url)
                }
        }
    }
}
