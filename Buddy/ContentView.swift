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
                VStack(spacing: 28) {
                    statusHero
                    captureButton
                    if micStatus != .granted { micPermissionCard }
                    recordingsList
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(BuddyBackground().ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("BUDDY")
                        .font(BuddyFont.display(20))
                        .tracking(3)
                        .foregroundStyle(BuddyPalette.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(BuddyPalette.ink)
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
        VStack(spacing: 14) {
            PixelScene(isListening: recorder.isRunning, pulse: pulse)
                .frame(height: 220)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text(recorder.isRunning ? "LISTENING" : "PAUSED")
                    .font(BuddyFont.display(22))
                    .tracking(3)
                    .foregroundStyle(BuddyPalette.ink)
                Text(recorder.isRunning
                     ? "The last \(settings.bufferSeconds) seconds are ready to send."
                     : "Turn on listening in Settings to start buffering.")
                    .font(BuddyFont.body(14))
                    .foregroundStyle(BuddyPalette.ink.opacity(0.7))
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
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .heavy))
                Text("SEND THE LAST \(settings.bufferSeconds)s")
                    .font(BuddyFont.display(15))
                    .tracking(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .foregroundStyle(BuddyPalette.ink)
            .background(BuddyPalette.sunshine)
            .pixelBorder(radius: 14, lineWidth: 3)
            .pixelDropShadow()
        }
        .buttonStyle(PixelPressStyle())
        .disabled(!recorder.isRunning)
        .opacity(recorder.isRunning ? 1 : 0.55)
    }

    private var micPermissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("MIC ACCESS NEEDED")
                    .font(BuddyFont.display(14))
                    .tracking(2)
            } icon: {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 16, weight: .heavy))
            }
            .foregroundStyle(BuddyPalette.ink)

            Text("Grant access so Buddy can keep the rolling buffer alive.")
                .font(BuddyFont.body(13))
                .foregroundStyle(BuddyPalette.ink.opacity(0.7))

            Button {
                requestMic()
            } label: {
                Text("ALLOW MICROPHONE")
                    .font(BuddyFont.display(13))
                    .tracking(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(BuddyPalette.cream)
                    .background(BuddyPalette.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PixelPressStyle())
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BuddyPalette.cream)
        .pixelBorder(radius: 14, lineWidth: 3)
    }

    // MARK: - Recordings

    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("RECORDINGS")
                    .font(BuddyFont.display(16))
                    .tracking(2.5)
                    .foregroundStyle(BuddyPalette.ink)
                Spacer()
                if !diskCaptures.isEmpty {
                    Text("\(diskCaptures.count)")
                        .font(BuddyFont.display(13))
                        .foregroundStyle(BuddyPalette.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(BuddyPalette.sunshine)
                        .pixelBorder(radius: 6, lineWidth: 2)
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
        .padding(.top, 8)
    }

    private var emptyRecordings: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(BuddyPalette.ink.opacity(0.4))
            Text("NO RECORDINGS YET")
                .font(BuddyFont.display(14))
                .tracking(2)
                .foregroundStyle(BuddyPalette.ink.opacity(0.75))
            Text("Press the Action Button to capture the last \(settings.bufferSeconds)s.")
                .font(BuddyFont.body(12))
                .foregroundStyle(BuddyPalette.ink.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(BuddyPalette.cream)
        .pixelBorder(radius: 14, lineWidth: 3)
    }

    // MARK: - Helpers

    private func matchedRecord(for url: URL) -> CaptureRecord? {
        // Match by filename — full-URL equality fails when one side is
        // /var/... and the other is /private/var/... on iOS.
        let name = url.lastPathComponent
        return recorder.recentCaptures.first(where: { $0.fileURL.lastPathComponent == name })
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

// MARK: - Buddy palette + fonts

enum BuddyPalette {
    static let sky       = Color(red: 0.42, green: 0.76, blue: 0.91)   // #6CC2E8
    static let skyLight  = Color(red: 0.72, green: 0.88, blue: 0.95)   // #B8E1F2
    static let grass     = Color(red: 0.36, green: 0.71, blue: 0.37)   // #5BB55F
    static let grassDeep = Color(red: 0.24, green: 0.62, blue: 0.27)   // #3D9D45
    static let ink       = Color(red: 0.06, green: 0.10, blue: 0.21)   // #0F1A36
    static let cream     = Color(red: 1.00, green: 0.97, blue: 0.91)   // #FFF8E8
    static let sunshine  = Color(red: 0.96, green: 0.83, blue: 0.30)   // #F6D44C
    static let coral     = Color(red: 0.90, green: 0.47, blue: 0.24)   // #E5773D
    static let tan       = Color(red: 0.78, green: 0.54, blue: 0.32)   // #C68A53
    static let cloud     = Color.white
}

enum BuddyFont {
    /// Chunky monospaced display — pixel-art feel for headings, labels, buttons.
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .monospaced)
    }
    /// Friendly rounded body for readable copy.
    static func body(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .rounded)
    }
}

// MARK: - Pixel styling modifiers

private struct PixelBorder: ViewModifier {
    var radius: CGFloat
    var lineWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(BuddyPalette.ink, lineWidth: lineWidth)
            )
    }
}

private struct PixelDropShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(color: BuddyPalette.ink.opacity(0.35), radius: 0, x: 0, y: 4)
    }
}

extension View {
    func pixelBorder(radius: CGFloat = 12, lineWidth: CGFloat = 3) -> some View {
        modifier(PixelBorder(radius: radius, lineWidth: lineWidth))
    }
    func pixelDropShadow() -> some View {
        modifier(PixelDropShadow())
    }
}

struct PixelPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Backgrounds and pixel scene

private struct BuddyBackground: View {
    var body: some View {
        LinearGradient(
            colors: [BuddyPalette.skyLight, BuddyPalette.sky.opacity(0.85), BuddyPalette.grass.opacity(0.5), BuddyPalette.grassDeep.opacity(0.6)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct Cloud: View {
    var body: some View {
        ZStack {
            Capsule().fill(BuddyPalette.cloud)
            Circle().fill(BuddyPalette.cloud).offset(x: -10).scaleEffect(1.2)
            Circle().fill(BuddyPalette.cloud).offset(x: 12).scaleEffect(0.9)
        }
    }
}

private struct PixelScene: View {
    let isListening: Bool
    let pulse: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let horizon = h * 0.62

            ZStack {
                // Sky
                BuddyPalette.sky
                    .frame(width: w, height: h)

                // Distant cloud band (pixel-y)
                HStack(spacing: 18) {
                    Cloud().frame(width: 56, height: 16)
                    Spacer()
                    Cloud().frame(width: 70, height: 18)
                }
                .padding(.horizontal, 18)
                .offset(y: -h * 0.18)

                // Grass field
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LinearGradient(
                        colors: [BuddyPalette.grass, BuddyPalette.grassDeep],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: h - horizon)
                }

                // Flowers on the grass
                Flower(color: BuddyPalette.coral)
                    .frame(width: 14, height: 22)
                    .position(x: 28, y: horizon + (h - horizon) * 0.55)
                Flower(color: BuddyPalette.sunshine)
                    .frame(width: 14, height: 22)
                    .position(x: w - 32, y: horizon + (h - horizon) * 0.45)
                Flower(color: BuddyPalette.coral)
                    .frame(width: 12, height: 18)
                    .position(x: 60, y: horizon + (h - horizon) * 0.78)

                // Listening rings
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(BuddyPalette.ink.opacity(0.18), lineWidth: 2)
                        .frame(width: 96 + CGFloat(i * 26), height: 96 + CGFloat(i * 26))
                        .scaleEffect(isListening && pulse ? 1.06 : 1.0)
                        .opacity(isListening && pulse ? 0.4 : 0.85)
                        .animation(
                            isListening
                                ? .easeInOut(duration: 2.4 + Double(i) * 0.4).repeatForever(autoreverses: true)
                                : .default,
                            value: pulse
                        )
                        .position(x: w / 2, y: horizon - 18)
                }

                // Mic medallion: chunky pixel-art block
                ZStack {
                    Circle()
                        .fill(BuddyPalette.sunshine)
                        .frame(width: 92, height: 92)
                    Circle()
                        .stroke(BuddyPalette.ink, lineWidth: 4)
                        .frame(width: 92, height: 92)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 44, weight: .black))
                        .foregroundStyle(BuddyPalette.ink)
                }
                .position(x: w / 2, y: horizon - 18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(BuddyPalette.ink, lineWidth: 4)
            )
            .shadow(color: BuddyPalette.ink.opacity(0.35), radius: 0, x: 0, y: 6)
        }
    }
}

private struct Flower: View {
    let color: Color
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(color)
                Circle().fill(BuddyPalette.ink).frame(width: 4, height: 4)
            }
            .frame(width: 12, height: 12)
            Rectangle()
                .fill(BuddyPalette.grassDeep)
                .frame(width: 2, height: 10)
        }
    }
}

// MARK: - Recording card

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
                        .fill(isPlaying ? BuddyPalette.coral : BuddyPalette.sunshine)
                        .frame(width: 46, height: 46)
                    Circle()
                        .stroke(BuddyPalette.ink, lineWidth: 2.5)
                        .frame(width: 46, height: 46)
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(BuddyPalette.ink)
                }
            }
            .buttonStyle(PixelPressStyle())

            VStack(alignment: .leading, spacing: 6) {
                Text(meta.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(BuddyFont.display(14))
                    .tracking(1.5)
                    .foregroundStyle(BuddyPalette.ink)
                if let summary = transcriptSummary {
                    Text(summary)
                        .font(BuddyFont.body(13))
                        .foregroundStyle(BuddyPalette.ink)
                        .lineLimit(3)
                } else {
                    Text(stateLabel)
                        .font(BuddyFont.body(12))
                        .foregroundStyle(stateColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(BuddyPalette.cream)
        .pixelBorder(radius: 14, lineWidth: 3)
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
        case .failed?: return BuddyPalette.coral
        case .uploading?: return BuddyPalette.ink.opacity(0.7)
        default: return BuddyPalette.ink.opacity(0.55)
        }
    }
}
