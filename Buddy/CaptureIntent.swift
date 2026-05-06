import AppIntents
import Foundation

struct CaptureLast30sIntent: AppIntent {
    static var title: LocalizedStringResource = "Tell Buddy"
    static var description = IntentDescription(
        "Sends the most recent rolling-buffer clip to your Buddy agent."
    )

    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let record = await RecorderController.shared.captureLast30Seconds(reason: "intent")
        guard record != nil else {
            return .result(dialog: "Whimper… no audio. Check mic access.")
        }
        return .result(dialog: "Ruff! On it.")
    }
}

struct BuddyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureLast30sIntent(),
            phrases: [
                "Tell \(.applicationName)",
                "\(.applicationName), got something for you",
                "Send to \(.applicationName)",
                "תפוס עם \(.applicationName)",
            ],
            shortTitle: "Tell Buddy",
            systemImageName: "ear"
        )
    }
}
