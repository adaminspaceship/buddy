import Foundation
import os

/// Parses `buddy://configure?endpoint=<url>&token=<bearer>` and writes the
/// values into SettingsStore. Used by the OpenClaw plugin's QR-code onboarding
/// flow so the user never has to type a URL.
enum DeepLinkHandler {
    private static let log = Logger(subsystem: "com.trycaret.buddy", category: "DeepLink")

    static func handle(_ url: URL) {
        guard url.scheme == "buddy" else { return }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        switch comps.host {
        case "configure":
            let items = comps.queryItems ?? []
            if let endpoint = items.first(where: { $0.name == "endpoint" })?.value,
               let decoded = endpoint.removingPercentEncoding,
               !decoded.isEmpty {
                Task { @MainActor in
                    SettingsStore.shared.uploadURL = decoded
                }
            }
            if let token = items.first(where: { $0.name == "token" })?.value,
               let decoded = token.removingPercentEncoding {
                Task { @MainActor in
                    SettingsStore.shared.authToken = decoded
                }
            }
            log.info("Applied configure deep link: \(url.absoluteString, privacy: .public)")
        default:
            log.error("Unknown deep-link host: \(comps.host ?? "nil", privacy: .public)")
        }
    }
}
