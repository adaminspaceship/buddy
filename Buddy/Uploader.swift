import Foundation
import os
import UIKit

/// Pipeline:
///   1. Transcribe the WAV locally via the user's ElevenLabs API key.
///   2. POST a small JSON payload `{ transcript, capturedAt, ... }` to the
///      configured OpenClaw plugin endpoint.
///
/// Wrapped in a UIBackgroundTask so it gets ~30s of background runtime if
/// the user pockets the phone right after triggering.
final class Uploader: NSObject {
    static let shared = Uploader()

    private let log = Logger(subsystem: "com.trycaret.buddy", category: "Uploader")
    private let session = URLSession(configuration: .ephemeral)

    func enqueue(_ record: CaptureRecord, completion: @escaping (CaptureRecord) -> Void) {
        let urlString = SettingsStore.shared.uploadURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlString), urlString.hasPrefix("http") else {
            var failed = record
            failed.uploadState = .failed(message: "Set the agent URL in Settings.")
            completion(failed)
            return
        }
        let apiKey = SettingsStore.shared.elevenlabsAPIKey.trimmingCharacters(in: .whitespaces)
        guard !apiKey.isEmpty else {
            var failed = record
            failed.uploadState = .failed(message: "Add your ElevenLabs API key in Settings.")
            completion(failed)
            return
        }

        var working = record
        working.uploadState = .transcribing
        completion(working)

        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "buddy-upload-\(record.id.uuidString)") {}
        Task.detached { [weak self] in
            guard let self else {
                UIApplication.shared.endBackgroundTask(bgTask)
                return
            }
            let result = await self.run(record: record, endpoint: url, apiKey: apiKey, completion: completion)
            UIApplication.shared.endBackgroundTask(bgTask)
            completion(result)
        }
    }

    private func run(record: CaptureRecord,
                     endpoint: URL,
                     apiKey: String,
                     completion: @escaping (CaptureRecord) -> Void) async -> CaptureRecord {
        // 1. Transcribe via ElevenLabs.
        let transcript: String
        do {
            transcript = try await Transcriber.transcribe(
                audioURL: record.fileURL,
                apiKey: apiKey,
                languageCodes: SettingsStore.shared.languageCodes
            )
        } catch {
            log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            var failed = record
            failed.uploadState = .failed(message: error.localizedDescription)
            return failed
        }

        // Surface the transcript to the UI immediately, even before the dispatch
        // round-trip completes — user can see what was heard.
        var uploading = record
        uploading.uploadState = .uploading
        completion(uploading)

        // 2. Dispatch the transcript to OpenClaw.
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = SettingsStore.shared.authToken
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 30

        let payload: [String: Any] = [
            "transcription": transcript,
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            var failed = record
            failed.uploadState = .failed(message: "Couldn't encode payload: \(error.localizedDescription)")
            return failed
        }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                var failed = record
                failed.uploadState = .failed(message: "No HTTP response.")
                return failed
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                var failed = record
                failed.uploadState = .failed(message: "HTTP \(http.statusCode): \(bodyStr)")
                return failed
            }
            var done = record
            done.uploadState = .uploaded(transcript: transcript)
            return done
        } catch {
            var failed = record
            failed.uploadState = .failed(message: error.localizedDescription)
            return failed
        }
    }

    /// Probe the configured endpoint with a JSON body the plugin will reject —
    /// the rejection itself proves the endpoint is reachable and authenticated.
    /// Returns nil on success, an error string on failure.
    func testConnection() async -> String? {
        let urlString = SettingsStore.shared.uploadURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlString), urlString.hasPrefix("http") else {
            return "URL is empty or invalid."
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = SettingsStore.shared.authToken
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Empty JSON — plugin should respond 400 (proves reachability + auth).
        req.httpBody = "{}".data(using: .utf8)
        req.timeoutInterval = 10

        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return "No HTTP response."
            }
            switch http.statusCode {
            case 200..<300, 400, 422:
                return nil
            case 401, 403:
                return "Connected, but auth was rejected (HTTP \(http.statusCode))."
            case 404:
                return "Endpoint not found at this URL (HTTP 404)."
            default:
                return "Unexpected response: HTTP \(http.statusCode)."
            }
        } catch {
            return error.localizedDescription
        }
    }
}
