import Foundation
import os

/// Background URLSession uploader. Streams the WAV from disk via
/// `uploadTask(with:fromFile:)` so the OS keeps the request alive past app
/// suspension and retries on flaky networks.
final class Uploader: NSObject {
    static let shared = Uploader()

    private let log = Logger(subsystem: "com.trycaret.buddy", category: "Uploader")

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.trycaret.buddy.upload")
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.allowsCellularAccess = true
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private struct Pending {
        var record: CaptureRecord
        let completion: (CaptureRecord) -> Void
        var responseBody: Data
        let stagedBodyURL: URL
    }
    private var pending: [Int: Pending] = [:]
    private let queue = DispatchQueue(label: "buddy.uploader.state")

    func enqueue(_ record: CaptureRecord, completion: @escaping (CaptureRecord) -> Void) {
        let urlString = SettingsStore.shared.uploadURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlString), urlString.hasPrefix("http") else {
            var failed = record
            failed.uploadState = .failed(message: "Set the agent URL in Settings.")
            completion(failed)
            return
        }

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

        // Background sessions require uploadTask(fromFile:) — the body has to
        // live on disk. Materialize the multipart envelope to a temp file.
        let bodyURL: URL
        do {
            bodyURL = try buildMultipartBody(audioURL: record.fileURL, boundary: boundary)
        } catch {
            var failed = record
            failed.uploadState = .failed(message: "Couldn't stage upload: \(error.localizedDescription)")
            completion(failed)
            return
        }

        let task = session.uploadTask(with: req, fromFile: bodyURL)
        var working = record
        working.uploadState = .uploading
        queue.sync {
            pending[task.taskIdentifier] = Pending(
                record: working,
                completion: completion,
                responseBody: Data(),
                stagedBodyURL: bodyURL
            )
        }
        completion(working)
        task.resume()
    }

    private func buildMultipartBody(audioURL: URL, boundary: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-upload-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        func write(_ s: String) throws {
            try handle.write(contentsOf: Data(s.utf8))
        }

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"audio\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        try write("Content-Type: audio/wav\r\n\r\n")
        let audioData = try Data(contentsOf: audioURL)
        try handle.write(contentsOf: audioData)
        try write("\r\n--\(boundary)--\r\n")
        return tmp
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
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
        // Empty form, no `audio` field — server should respond 4xx with a
        // clear error that proves it's the right endpoint.
        req.httpBody = "--\(boundary)--\r\n".data(using: .utf8)
        req.timeoutInterval = 10

        do {
            let probeSession = URLSession(configuration: .ephemeral)
            let (_, response) = try await probeSession.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return "No HTTP response."
            }
            switch http.statusCode {
            case 200..<300, 400, 422:
                // 2xx = served (unusual for empty body), 400/422 = endpoint
                // recognized the request and rejected it for the right reason.
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

extension Uploader: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.sync {
            pending[dataTask.taskIdentifier]?.responseBody.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let snapshot: Pending? = queue.sync {
            pending.removeValue(forKey: task.taskIdentifier)
        }
        guard let pending = snapshot else { return }
        cleanup(pending.stagedBodyURL)

        var record = pending.record
        if let error {
            record.uploadState = .failed(message: error.localizedDescription)
            pending.completion(record)
            return
        }
        guard let http = task.response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: pending.responseBody, encoding: .utf8) ?? ""
            record.uploadState = .failed(message: "HTTP \(code): \(body)")
            pending.completion(record)
            return
        }

        let transcript: String?
        if let obj = try? JSONSerialization.jsonObject(with: pending.responseBody) as? [String: Any] {
            transcript = (obj["transcription"] as? String) ?? (obj["text"] as? String)
        } else {
            let raw = String(data: pending.responseBody, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            transcript = (raw?.isEmpty == false) ? raw : nil
        }
        record.uploadState = .uploaded(transcript: transcript?.trimmingCharacters(in: .whitespacesAndNewlines))
        pending.completion(record)
    }
}
