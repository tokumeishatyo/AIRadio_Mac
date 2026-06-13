import Foundation
import AIRadioCore

/// VOICEVOX のローカル HTTP API で日本語テキストを WAV 合成する `TTSBackend` 実装。
/// `audio_query`（解析）→ `synthesis`（合成）の 2 段呼び出し。
public struct VoicevoxTTS: TTSBackend {
    private let base: URL
    private let http: any HTTPClient
    /// 話速（VOICEVOX の speedScale、1.0 = 標準）。`config/tts.yaml` の `speed_scale`。
    private let speedScale: Double

    public init(endpoint: String, http: any HTTPClient, speedScale: Double = 1.0) {
        self.base = URL(string: endpoint) ?? URL(string: "http://127.0.0.1:50021/")!
        self.http = http
        self.speedScale = speedScale
    }

    public func synthesize(text: String, speakerId: Int) async throws -> Data {
        do {
            let queryURL = makeURL("audio_query", [
                URLQueryItem(name: "text", value: Self.normalizeForSpeech(text)),
                URLQueryItem(name: "speaker", value: String(speakerId)),
            ])
            let query = try await http.post(url: queryURL, body: nil, headers: [:])

            let synthURL = makeURL("synthesis", [
                URLQueryItem(name: "speaker", value: String(speakerId)),
            ])
            let wav = try await http.post(
                url: synthURL,
                body: try applySpeed(to: query),
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

    /// 発話前のテキスト正規化。VOICEVOX は波ダッシュ「〜」(U+301C) / 全角チルダ「～」(U+FF5E) を
    /// 伸ばす音として読まず区切ってしまう（例: 「あ〜し」→「あ し」）。長音「ー」(U+30FC) に置換して
    /// 自然に伸ばす（つむぎのギャル口調などの伸ばし音対策、s13.5 ライブ調整）。
    static func normalizeForSpeech(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{301C}", with: "\u{30FC}")
            .replacingOccurrences(of: "\u{FF5E}", with: "\u{30FC}")
    }

    /// audio_query の結果 JSON に話速（speedScale）を適用する。標準速（1.0）なら無加工で返す。
    private func applySpeed(to query: Data) throws -> Data {
        guard speedScale != 1.0 else { return query }
        guard var object = try JSONSerialization.jsonObject(with: query) as? [String: Any] else {
            throw TtsError.synthesisFailed("audio_query の応答を解釈できません")
        }
        object["speedScale"] = speedScale
        return try JSONSerialization.data(withJSONObject: object)
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
