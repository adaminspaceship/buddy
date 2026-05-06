import Foundation
import os
import UIKit

/// Foreground URLSession uploader. Posts the WAV as multipart/form-data to the
/// configured server and awaits the response. Wrapped in a UIBackgroundTask so
/// it gets ~30s of background runtime if the user pockets the phone after
/// triggering — long enough for a 30s clip on any modern network.
///
/// We deliberately don't use URLSessionConfiguration.background — those have
/// silent-wait behaviors over plain HTTP and ATS edge cases that left uploads
/// stuck at "waiting to send" indefinitely. Foreground sessions just work.
final class Uploader: NSObject {
    static let shared = Uploader()

    private let log = Logger(subsystem: "com.trycaret.buddy", category: "Uploader")
    private let session = URLSession(configuration: .ephemeral)

    func enqueue(_ record: CaptureRecord, completion: @escaping (CaptureRecord) -> Void) {
        log.info("🔵 enqueue(\(record.id.uuidString, privacy: .public)) called")

        let urlString = SettingsStore.shared.uploadURL.trimmingCharacters(in: .whitespaces)
        log.info("🔵 url='\(urlString, privacy: .public)' tokenSet=\(!SettingsStore.shared.authToken.isEmpty, privacy: .public)")

        guard let url = URL(string: urlString), urlString.hasPrefix("http") else {
            log.error("🔴 URL invalid; bailing")
            var failed = record
            failed.uploadState = .failed(message: "Set the agent URL in Settings.")
            completion(failed)
            return
        }

        var working = record
        working.uploadState = .uploading
        log.info("🔵 firing completion(.uploading)")
        completion(working)

        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "buddy-upload-\(record.id.uuidString)") {
            // Expiration: nothing actionable here.
        }
        log.info("🔵 bgTask=\(bgTask.rawValue, privacy: .public) — kicking off detached upload")

        Task.detached { [weak self] in
            guard let self else {
                UIApplication.shared.endBackgroundTask(bgTask)
                return
            }
            let result = await self.runUpload(record: record, url: url)
            UIApplication.shared.endBackgroundTask(bgTask)
            self.log.info("🔵 firing completion(final) state=\(String(describing: result.uploadState), privacy: .public)")
            completion(result)
        }
    }

    private func runUpload(record: CaptureRecord, url: URL) async -> CaptureRecord {
        log.info("🟢 runUpload starting for \(url.absoluteString, privacy: .public)")
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let token = SettingsStore.shared.authToken
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let langs = SettingsStore.shared.languageCodes.joined(separator: ",")
        if !langs.isEmpty {
            req.setValue(langs, forHTTPHeaderField: "X-Language-Hints")
        }
        req.timeoutInterval = 60

        let body: Data
        do {
            body = try buildMultipartBody(audioURL: record.fileURL, boundary: boundary)
            log.info("🟢 multipart body built, \(body.count, privacy: .public) bytes")
        } catch {
            log.error("🔴 buildMultipartBody failed: \(error.localizedDescription, privacy: .public)")
            var failed = record
            failed.uploadState = .failed(message: "Couldn't stage upload: \(error.localizedDescription)")
            return failed
        }
        req.httpBody = body

        do {
            log.info("🟢 sending request…")
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                log.error("🔴 no HTTPURLResponse")
                var failed = record
                failed.uploadState = .failed(message: "No HTTP response.")
                return failed
            }
            log.info("🟢 got HTTP \(http.statusCode, privacy: .public), \(data.count, privacy: .public) bytes")
            guard (200..<300).contains(http.statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                log.error("🔴 HTTP \(http.statusCode, privacy: .public): \(bodyStr, privacy: .public)")
                var failed = record
                failed.uploadState = .failed(message: "HTTP \(http.statusCode): \(bodyStr)")
                return failed
            }
            let transcript: String?
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                transcript = (obj["transcription"] as? String) ?? (obj["text"] as? String)
            } else {
                let raw = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                transcript = (raw?.isEmpty == false) ? raw : nil
            }
            var done = record
            done.uploadState = .uploaded(transcript: transcript?.trimmingCharacters(in: .whitespacesAndNewlines))
            log.info("🟢 success, transcript=\(transcript ?? "<none>", privacy: .public)")
            return done
        } catch {
            log.error("🔴 upload threw: \(error.localizedDescription, privacy: .public)")
            var failed = record
            failed.uploadState = .failed(message: error.localizedDescription)
            return failed
        }
    }

    private func buildMultipartBody(audioURL: URL, boundary: String) throws -> Data {
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    /// Probe the configured endpoint with a tiny multipart that the plugin
    /// will reject — but the rejection itself proves the endpoint is reachable
    /// and authenticated. Returns nil on success, an error string on failure.
    func testConnection() async -> String? {
        let urlString = SettingsStore.shared.uploadURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlString), urlString.hasPrefix("http") else {
            return "URL is empty or invalid."
        }
        let boundary = "ProbeBoundary"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let token = SettingsStore.shared.authToken
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = "--\(boundary)--\r\n".data(using: .utf8)
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
