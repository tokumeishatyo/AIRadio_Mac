import Foundation
import AIRadioCore

/// VOICEVOX のローカル HTTP API で日本語テキストを WAV 合成する `TTSBackend` 実装。
/// `audio_query`（解析）→ `synthesis`（合成）の 2 段呼び出し。
public struct VoicevoxTTS: TTSBackend {
    private let base: URL
    private let http: any HTTPClient

    public init(endpoint: String, http: any HTTPClient) {
        self.base = URL(string: endpoint) ?? URL(string: "http://127.0.0.1:50021/")!
        self.http = http
    }

    public func synthesize(text: String, speakerId: Int) async throws -> Data {
        do {
            let queryURL = makeURL("audio_query", [
                URLQueryItem(name: "text", value: text),
                URLQueryItem(name: "speaker", value: String(speakerId)),
            ])
            let query = try await http.post(url: queryURL, body: nil, headers: [:])

            let synthURL = makeURL("synthesis", [
                URLQueryItem(name: "speaker", value: String(speakerId)),
            ])
            let wav = try await http.post(
                url: synthURL,
                body: query,
                headers: ["Content-Type": "application/json"]
            )
            return wav
        } catch let error as TtsError {
            throw error
        } catch is URLError {
            throw TtsError.unreachable
        } catch {
            throw TtsError.synthesisFailed(String(describing: error))
        }
    }

    private func makeURL(_ path: String, _ items: [URLQueryItem]) -> URL {
        var components = URLComponents(
            url: base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = items
        return components.url!
    }
}
