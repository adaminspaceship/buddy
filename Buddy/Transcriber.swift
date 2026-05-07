import Foundation
import os

/// Calls the ElevenLabs Scribe speech-to-text endpoint with the user's
/// own API key (configured in Settings). Returns the transcript text.
struct Transcriber {
    private static let log = Logger(subsystem: "com.trycaret.buddy", category: "Transcriber")
    private static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    private static let session = URLSession(configuration: .ephemeral)

    enum TranscribeError: LocalizedError {
        case missingAPIKey
        case http(Int, String)
        case emptyResponse
        case decode

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "Add your ElevenLabs API key in Settings."
            case .http(let code, let body): return "ElevenLabs HTTP \(code): \(body)"
            case .emptyResponse: return "ElevenLabs returned an empty transcript."
            case .decode: return "Couldn't read ElevenLabs response."
            }
        }
    }

    static func transcribe(audioURL: URL,
                           apiKey: String,
                           languageCodes: [String]) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw TranscribeError.missingAPIKey }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        appendField("model_id", "scribe_v1")
        appendField("diarize", "false")
        appendField("tag_audio_events", "false")
        // Scribe takes a single ISO-639-1 hint; pass the first selected language.
        if let first = languageCodes.first(where: { !$0.isEmpty }) {
            appendField("language_code", first)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: audioURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TranscribeError.http(0, "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            log.error("ElevenLabs failed: \(http.statusCode) \(bodyStr, privacy: .public)")
            throw TranscribeError.http(http.statusCode, bodyStr)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscribeError.decode
        }
        let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw TranscribeError.emptyResponse }
        return text
    }
}
