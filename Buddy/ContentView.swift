import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var recorder: RecorderController
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var playback = PlaybackController.shared
    @State private var micStatus: AVAudioSession.RecordPermission = AVAudioSession.sharedInstance().recordPermission
    @State private var diskCaptures: [URL] = []
    @State private var showSettings = false
    @State private var pulse = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    statusHero
                    captureButton
                    if micStatus != .granted { micPermissionCard }
                    recordingsList
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .background(BuddyBackground().ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("Buddy")
                        .font(.custom("AmericanTypewriter-Bold", size: 22))
                        .foregroundStyle(BuddyPalette.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(BuddyPalette.ink.opacity(0.6))
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(settings)
            }
            .onAppear {
                if settings.alwaysOn && !recorder.isRunning && micStatus == .granted {
                    recorder.start()
                }
                refreshDiskCaptures()
                pulse = true
            }
            .onChange(of: recorder.lastCapture?.id) { _, _ in
                refreshDiskCaptures()
            }
            .onDisappear { playback.stop() }
        }
    }

    // MARK: - Hero

    private var statusHero: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(BuddyPalette.tan.opacity(0.45), lineWidth: 1.2)
                        .frame(width: 150 + CGFloat(i * 26), height: 150 + CGFloat(i * 26))
                        .scaleEffect(recorder.isRunning && pulse ? 1.05 : 1.0)
                        .opacity(recorder.isRunning && pulse ? 0.55 : 1.0)
                        .animation(
                            recorder.isRunning ?
                                .easeInOut(duration: 2.4 + Double(i) * 0.4)
                                .repeatForever(autoreverses: true) :
                                .default,
                            value: pulse
                        )
                }
                Circle()
                    .fill(BuddyPalette.dogFur)
                    .frame(width: 130, height: 130)
                Text("🐕")
                    .font(.system(size: 64))
                    .offset(y: -2)
            }
            .padding(.top, 20)

            VStack(spacing: 6) {
                Text(recorder.isRunning ? "I'm listening." : "Sleeping.")
                    .font(.custom("AmericanTypewriter", size: 26))
                    .foregroundStyle(BuddyPalette.ink)
                Text(recorder.isRunning
                     ? "The last \(settings.bufferSeconds) seconds are always ready to send."
                     : "Wake me up in Settings to start buffering.")
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(BuddyPalette.ink.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Primary action

    private var captureButton: some View {
        Button {
            Task {
                await recorder.captureLast30Seconds(reason: "manual")
                refreshDiskCaptures()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "pawprint.fill")
                Text("Send the last \(settings.bufferSeconds)s")
                    .font(.custom("AmericanTypewriter-Bold", size: 17))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(BuddyPalette.ink)
            .foregroundStyle(BuddyPalette.cream)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: BuddyPalette.ink.opacity(0.18), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(!recorder.isRunning)
        .opacity(recorder.isRunning ? 1 : 0.5)
    }

    private var micPermissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Microphone access needed", systemImage: "mic.slash.fill")
                .font(.system(.headline, design: .serif))
            Text("Buddy needs the mic to keep his ear out for you.")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(.secondary)
            Button("Allow microphone") { requestMic() }
                .buttonStyle(.borderedProminent)
                .tint(BuddyPalette.ink)
                .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BuddyPalette.cream.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Recordings

    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Fetched")
                    .font(.custom("AmericanTypewriter-Bold", size: 20))
                    .foregroundStyle(BuddyPalette.ink)
                Spacer()
                if !diskCaptures.isEmpty {
                    Text("\(diskCaptures.count)")
                        .font(.system(.caption, design: .serif).monospacedDigit())
                        .foregroundStyle(BuddyPalette.ink.opacity(0.55))
                }
            }
            if diskCaptures.isEmpty {
                emptyRecordings
            } else {
                VStack(spacing: 12) {
                    ForEach(diskCaptures, id: \.self) { url in
                        RecordingCard(
                            url: url,
                            meta: captureMetadata(for: url),
                            uploadState: matchedRecord(for: url)?.uploadState,
                            isPlaying: playback.playingURL == url,
                            onPlayToggle: { playback.toggle(url) },
                            onDelete: { delete(url) }
                        )
                    }
                }
            }
        }
        .padding(.top, 12)
    }

    private var emptyRecordings: some View {
        VStack(spacing: 12) {
            Image(systemName: "pawprint")
                .font(.system(size: 32))
                .foregroundStyle(BuddyPalette.ink.opacity(0.35))
            Text("No fetches yet")
                .font(.custom("AmericanTypewriter", size: 17))
                .foregroundStyle(BuddyPalette.ink.opacity(0.7))
            Text("Press the Action Button to send Buddy off.")
                .font(.system(.caption, design: .serif))
                .foregroundStyle(BuddyPalette.ink.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(BuddyPalette.cream.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Helpers

    private func matchedRecord(for url: URL) -> CaptureRecord? {
        recorder.recentCaptures.first(where: { $0.fileURL == url })
    }

    private func captureMetadata(for url: URL) -> CaptureMeta {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) ?? Date()
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return CaptureMeta(date: date, sizeKB: bytes / 1024)
    }

    private func refreshDiskCaptures() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("captures", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        diskCaptures = urls
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return lDate > rDate
            }
    }

    private func delete(_ url: URL) {
        if playback.playingURL == url { playback.stop() }
        try? FileManager.default.removeItem(at: url)
        refreshDiskCaptures()
    }

    private func requestMic() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                micStatus = granted ? .granted : .denied
                if granted && settings.alwaysOn { recorder.start() }
            }
        }
    }
}

struct CaptureMeta {
    let date: Date
    let sizeKB: Int
}

// MARK: - Buddy palette + background

enum BuddyPalette {
    static let cream = Color(red: 0.97, green: 0.94, blue: 0.88)        // #F8F0E0
    static let tan = Color(red: 0.84, green: 0.74, blue: 0.55)           // #D6BC8C
    static let dogFur = Color(red: 0.78, green: 0.55, blue: 0.32)        // #C68C52
    static let ink = Color(red: 0.18, green: 0.14, blue: 0.10)           // #2D241A
    static let meadow = Color(red: 0.72, green: 0.78, blue: 0.55)        // #B8C68C
    static let sky = Color(red: 0.82, green: 0.89, blue: 0.92)           // #D2E2EB
}

private struct BuddyBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [BuddyPalette.sky.opacity(0.7), BuddyPalette.cream, BuddyPalette.meadow.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct RecordingCard: View {
    let url: URL
    let meta: CaptureMeta
    let uploadState: CaptureRecord.UploadState?
    let isPlaying: Bool
    let onPlayToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onPlayToggle) {
                ZStack {
                    Circle()
                        .fill(isPlaying ? BuddyPalette.dogFur.opacity(0.25) : BuddyPalette.ink.opacity(0.08))
                        .frame(width: 46, height: 46)
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(BuddyPalette.ink)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text(meta.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.custom("AmericanTypewriter-Bold", size: 15))
                    .foregroundStyle(BuddyPalette.ink)
                if let summary = transcriptSummary {
                    Text(summary)
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(BuddyPalette.ink)
                        .lineLimit(3)
                } else {
                    Text(stateLabel)
                        .font(.system(.caption, design: .serif))
                        .foregroundStyle(stateColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(BuddyPalette.cream.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .swipeActions {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var transcriptSummary: String? {
        guard case .uploaded(let t?) = uploadState, !t.isEmpty else { return nil }
        return t
    }

    private var stateLabel: String {
        switch uploadState {
        case .none, .pending?: return "Saved · waiting to send"
        case .uploading?: return "Sending to your agent…"
        case .uploaded(.none)?: return "Sent · agent is on it"
        case .uploaded(.some)?: return ""
        case .failed(let m)?: return "Couldn't send: \(m)"
        }
    }

    private var stateColor: Color {
        switch uploadState {
        case .failed?: return .red
        case .uploading?: return BuddyPalette.dogFur
        default: return BuddyPalette.ink.opacity(0.55)
        }
    }
}
