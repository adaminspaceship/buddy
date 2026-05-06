import Foundation
import Combine

struct BufferDuration: Identifiable, Hashable {
    let seconds: Int
    var id: Int { seconds }
    var label: String {
        switch seconds {
        case ..<60: return "\(seconds)s"
        case 60: return "1 min"
        default: return "\(seconds / 60) min"
        }
    }
    static let presets: [BufferDuration] = [10, 30, 60, 120, 180].map(BufferDuration.init)
}

struct LanguageOption: Identifiable, Hashable, Codable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [LanguageOption] = [
        .init(code: "en", name: "English"),
        .init(code: "he", name: "Hebrew"),
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "ru", name: "Russian"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "tr", name: "Turkish"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "pl", name: "Polish"),
        .init(code: "uk", name: "Ukrainian"),
    ]
    static func find(_ code: String) -> LanguageOption? {
        all.first { $0.code == code }
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let alwaysOn = "alwaysOn"
        static let uploadURL = "uploadURL"
        static let authToken = "authToken"
        static let bufferSeconds = "bufferSeconds"
        static let languageCodes = "languageCodes"
    }

    private enum Defaults {
        static let uploadURL = ""
        static let authToken = ""
        static let bufferSeconds = 30
        static let languageCodes = ["en"]
    }

    @Published var alwaysOn: Bool { didSet { defaults.set(alwaysOn, forKey: Keys.alwaysOn) } }
    @Published var uploadURL: String { didSet { defaults.set(uploadURL, forKey: Keys.uploadURL) } }
    @Published var authToken: String { didSet { defaults.set(authToken, forKey: Keys.authToken) } }
    @Published var bufferSeconds: Int {
        didSet {
            defaults.set(bufferSeconds, forKey: Keys.bufferSeconds)
            // Rebuild the rolling buffer with the new size when the user changes it.
            Task { @MainActor in
                if RecorderController.shared.isRunning {
                    RecorderController.shared.stop()
                    RecorderController.shared.start()
                }
            }
        }
    }
    @Published var languageCodes: [String] {
        didSet { defaults.set(languageCodes, forKey: Keys.languageCodes) }
    }

    var languages: [LanguageOption] {
        languageCodes.compactMap(LanguageOption.find)
    }

    private init() {
        self.alwaysOn = defaults.object(forKey: Keys.alwaysOn) as? Bool ?? true
        self.uploadURL = defaults.string(forKey: Keys.uploadURL) ?? Defaults.uploadURL
        self.authToken = defaults.string(forKey: Keys.authToken) ?? Defaults.authToken
        self.bufferSeconds = defaults.object(forKey: Keys.bufferSeconds) as? Int ?? Defaults.bufferSeconds
        self.languageCodes = (defaults.array(forKey: Keys.languageCodes) as? [String])
            ?? Defaults.languageCodes
    }
}
