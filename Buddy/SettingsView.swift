import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var connectionResult: ConnectionResult?

    enum ConnectionResult: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Always listening", isOn: $settings.alwaysOn)
                    Picker("Buffer length", selection: $settings.bufferSeconds) {
                        ForEach(BufferDuration.presets) { d in
                            Text(d.label).tag(d.seconds)
                        }
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Buddy keeps the most recent \(currentDurationLabel) ready to send the moment you press the Action Button.")
                }

                Section {
                    SecureField("xi-api-key from elevenlabs.io", text: $settings.elevenlabsAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    NavigationLink {
                        LanguagePickerView(selected: $settings.languageCodes)
                    } label: {
                        HStack {
                            Text("Languages")
                            Spacer()
                            Text(languagesSummary)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("Buddy transcribes locally with ElevenLabs Scribe using your own key, then sends only the text to your agent. Get a key at elevenlabs.io/app/settings/api-keys.")
                }

                Section {
                    TextField("https://your-agent.example.com/voice", text: $settings.uploadURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Bearer token (optional)", text: $settings.authToken)
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("Test connection")
                        }
                    }
                    if let result = connectionResult {
                        switch result {
                        case .success:
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let msg):
                            Label(msg, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Or scan a configure-by-QR code from your agent's setup page to fill these in automatically.")
                }

                Section {
                    Link(destination: URL(string: "App-Prefs:")!) {
                        Label("Open iOS Settings", systemImage: "arrow.up.right.square")
                    }
                } footer: {
                    Text("Map the Action Button: iOS Settings → Action Button → Shortcut → Tell Buddy.")
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("SETTINGS")
                        .font(BuddyFont.display(18))
                        .tracking(3)
                        .foregroundStyle(BuddyPalette.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(BuddyFont.display(14))
                        .foregroundStyle(BuddyPalette.ink)
                }
            }
            .tint(BuddyPalette.ink)
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [BuddyPalette.skyLight, BuddyPalette.cream],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            )
        }
    }

    private var currentDurationLabel: String {
        BufferDuration.presets.first(where: { $0.seconds == settings.bufferSeconds })?.label
            ?? "\(settings.bufferSeconds)s"
    }

    private var languagesSummary: String {
        let langs = settings.languages
        if langs.isEmpty { return "None" }
        if langs.count == 1 { return langs[0].name }
        return langs.prefix(2).map(\.name).joined(separator: ", ")
            + (langs.count > 2 ? " +\(langs.count - 2)" : "")
    }

    private func testConnection() async {
        connectionResult = nil
        let result = await Uploader.shared.testConnection()
        connectionResult = result.map(ConnectionResult.failure) ?? .success
    }
}

private struct LanguagePickerView: View {
    @Binding var selected: [String]

    var body: some View {
        List(LanguageOption.all) { option in
            HStack {
                Text(option.name)
                Spacer()
                if selected.contains(option.code) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(option.code) }
        }
        .navigationTitle("Languages")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ code: String) {
        if let idx = selected.firstIndex(of: code) {
            // Don't let the user clear all languages — at least one must remain.
            if selected.count > 1 { selected.remove(at: idx) }
        } else {
            selected.append(code)
        }
    }
}
