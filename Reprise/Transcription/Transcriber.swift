import AVFoundation
import Security

/// Any service that speaks the OpenAI `POST /audio/transcriptions` dialect:
/// Refrain, OpenAI, Groq, Mistral, or a local whisper server (speaches, whisper.cpp, LocalAI…).
nonisolated struct TranscriptionService: Sendable {
    var baseURL: String
    var model: String

    /// Refrain transcribes on this Mac's Neural Engine and picks the model itself
    /// (github.com/nikiomori/Refrain).
    static let refrain = TranscriptionService(baseURL: "http://127.0.0.1:8178/v1", model: "auto")

    static let presets: [(name: String, service: TranscriptionService)] = [
        (String(localized: "Refrain (this Mac)"), refrain),
        ("OpenAI", .init(baseURL: "https://api.openai.com/v1", model: "gpt-4o-transcribe")),
        ("Groq", .init(baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo")),
        ("Mistral", .init(baseURL: "https://api.mistral.ai/v1", model: "voxtral-mini-latest")),
        (String(localized: "Local server"), .init(baseURL: "http://localhost:8000/v1", model: "Systran/faster-whisper-large-v3")),
    ]

    /// Whether Refrain answers on this Mac, for Settings to offer it. A second at most: it's
    /// local or it isn't there.
    static func refrainIsRunning() async -> Bool {
        guard let url = URL(string: refrain.baseURL)?.appending(path: "models"),
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 1)),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        return String(decoding: data, as: UTF8.self).contains(#""owned_by":"refrain""#)
    }
}

/// Transcription settings, persisted in UserDefaults (API key in the Keychain).
enum TranscriptionSettings {
    static let baseURLKey = "transcription.baseURL"
    static let modelKey = "transcription.model"
    static let languageKey = "transcription.language"
    static let autoKey = "transcription.auto"

    static var service: TranscriptionService? {
        let defaults = UserDefaults.standard
        guard let baseURL = defaults.string(forKey: baseURLKey), !baseURL.isEmpty,
              let model = defaults.string(forKey: modelKey), !model.isEmpty
        else { return nil }
        return TranscriptionService(baseURL: baseURL, model: model)
    }

    /// Stored per server host, so switching services never sends a key to another host.
    static var apiKey: String? {
        get { Keychain.read(account: keyAccount) }
        set { Keychain.write(newValue, account: keyAccount) }
    }

    private static var keyAccount: String {
        let baseURL = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
        return URL(string: baseURL)?.host() ?? baseURL
    }
}

/// `transcript.json`: what was said, phrase by phrase. `start` and `end` are seconds into the call;
/// `speaker` is "you" or "them", from the side it was heard on.
nonisolated struct Transcript: Codable {
    nonisolated struct Segment: Codable, Equatable {
        var speaker: String?
        var start: Double
        var end: Double
        var text: String
    }

    var segments: [Segment]

    /// For `transcript.txt`, which search, Copy and the shortcut after a call read: a paragraph each
    /// time the speaker changes, "You: …".
    var text: String {
        var turns: [(speaker: String?, text: String)] = []
        for segment in segments {
            if turns.last?.speaker == segment.speaker {
                turns[turns.count - 1].text += " " + segment.text
            } else {
                turns.append((segment.speaker, segment.text))
            }
        }
        return turns.map { "\(Self.name(of: $0.speaker)): \($0.text)" }.joined(separator: "\n\n")
    }

    static func name(of speaker: String?) -> String {
        speaker == "you" ? String(localized: "You") : String(localized: "Others")
    }
}

nonisolated enum Transcriber {
    /// The mix, as plain text.
    static func transcribe(
        _ audio: URL, service: TranscriptionService, apiKey: String?, language: String?,
        progress: @Sendable (Double) async -> Void
    ) async throws -> String {
        try await pieces(of: audio, timed: false, service: service, apiKey: apiKey, language: language, progress: progress)
            .joined().map(\.text).joined(separator: " ")
    }

    /// Each side on its own, with times (`verbose_json`): who said what, without guessing from
    /// voices. `nil` when the service doesn't time its text; the mix is transcribed instead.
    static func transcribe(
        you: URL, them: URL, service: TranscriptionService, apiKey: String?, language: String?,
        progress: @Sendable (Double) async -> Void
    ) async throws -> Transcript? {
        do {
            let mine = try await pieces(of: you, timed: true, service: service, apiKey: apiKey, language: language) { await progress($0 / 2) }
            let theirs = try await pieces(of: them, timed: true, service: service, apiKey: apiKey, language: language) { await progress(0.5 + $0 / 2) }
            return merge(you: mine, them: theirs)
        } catch is Untimed {
            return nil
        }
    }

    /// Both sides in the order they were said. Each comes as its pieces' phrases, timed from the
    /// start of their piece; the transcript times them from the start of the call.
    static func merge(you: [[Transcript.Segment]], them: [[Transcript.Segment]]) -> Transcript {
        let segments = [("you", you), ("them", them)].flatMap { speaker, pieces in
            pieces.enumerated().flatMap { index, piece in
                // To the millisecond: 600 + 12.34 would be 612.3399999999999 in the file.
                let time = { (($0 + Double(index) * chunk) * 1000).rounded() / 1000 }
                return piece.map { Transcript.Segment(speaker: speaker, start: time($0.start), end: time($0.end), text: $0.text) }
            }
        }
        return Transcript(segments: segments.sorted { $0.start < $1.start })
    }

    /// Long recordings are split into 10-minute pieces to stay under the
    /// 25 MB / duration limits most providers enforce.
    private static let chunk: Double = 600

    /// Each piece's phrases, timed from the start of the piece; untimed, a piece is one phrase.
    /// Off the main thread: each piece is read whole into the upload.
    @concurrent private static func pieces(
        of audio: URL, timed: Bool, service: TranscriptionService, apiKey: String?, language: String?,
        progress: @Sendable (Double) async -> Void
    ) async throws -> [[Transcript.Segment]] {
        let asset = AVURLAsset(url: audio)
        let duration = try await asset.load(.duration).seconds
        var phrases: [[Transcript.Segment]] = []
        var start: Double = 0
        repeat {
            await progress(start / max(duration, 1))
            let piece: URL
            if duration <= chunk {
                piece = audio
            } else {
                piece = FileManager.default.temporaryDirectory.appending(path: "reprise-\(UUID().uuidString).m4a")
                guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw Failure("Couldn't prepare the audio for upload.")
                }
                export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                               duration: CMTime(seconds: min(chunk, duration - start), preferredTimescale: 600))
                try await export.export(to: piece, as: .m4a)
            }
            defer { if piece != audio { try? FileManager.default.removeItem(at: piece) } }
            // The tail of the previous piece keeps names and spelling consistent across chunks.
            let text = phrases.joined().map(\.text).joined(separator: " ")
            phrases.append(try await upload(piece, timed: timed, service: service, apiKey: apiKey, language: language, prompt: String(text.suffix(400))))
            start += chunk
        } while start < duration
        await progress(1)
        return phrases
    }

    private static func upload(_ file: URL, timed: Bool, service: TranscriptionService, apiKey: String?, language: String?, prompt: String) async throws -> [Transcript.Segment] {
        guard let url = URL(string: service.baseURL)?.appending(path: "audio/transcriptions") else {
            throw Failure("The server address isn't a valid URL.")
        }
        let boundary = "reprise-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: 900)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", service.model)
        field("response_format", timed ? "verbose_json" : "json")
        if let language, !language.isEmpty { field("language", language) }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // A service that can't time its text turns `verbose_json` down as a bad request.
            if timed, [400, 422].contains(status) { throw Untimed() }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8)?.prefix(300).description
            throw Failure("The service answered \(status): \(message ?? String(localized: "no details")).")
        }
        let segments: [Transcript.Segment]
        if timed {
            guard let answer = try? JSONDecoder().decode(Transcript.self, from: data) else { throw Untimed() } // without `segments`
            segments = answer.segments
        } else {
            segments = [.init(start: 0, end: 0, text: try JSONDecoder().decode(TextBody.self, from: data).text)]
        }
        return segments.map { .init(start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
    }

    private struct Untimed: Error {}
    private struct TextBody: Decodable { let text: String }
    private struct ErrorBody: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }
}

/// The API key lives in the login Keychain, never in preferences.
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.nikiomori.reprise.transcription",
            kSecAttrAccount as String: account,
        ]
    }

    static func read(account: String) -> String? {
        var result: AnyObject?
        var query = query(account)
        query[kSecReturnData as String] = true
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
