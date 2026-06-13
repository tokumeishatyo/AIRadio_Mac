import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

struct VoicevoxTTSTests {
    @Test func callsAudioQueryThenSynthesisAndReturnsWav() async throws {
        let queryJSON = Data("{\"accent_phrases\":[]}".utf8)
        let wavBytes = Data("RIFF....WAVEfake".utf8)
        let fake = FakeHTTPClient { url in
            url.path.contains("audio_query") ? queryJSON : wavBytes
        }
        let tts = VoicevoxTTS(endpoint: "http://127.0.0.1:50021/", http: fake)

        let out = try await tts.synthesize(text: "テスト", speakerId: 3)

        #expect(out == wavBytes)
        #expect(fake.requests.count == 2)

        let q = fake.requests[0]
        #expect(q.url.path.contains("audio_query"))
        #expect(q.url.query?.contains("speaker=3") == true)
        #expect(q.url.query?.contains("text=") == true)

        let s = fake.requests[1]
        #expect(s.url.path.contains("synthesis"))
        #expect(s.url.query?.contains("speaker=3") == true)
        #expect(s.body == queryJSON)
        #expect(s.headers["Content-Type"] == "application/json")
    }

    @Test func appliesSpeedScaleToQuery() async throws {
        let queryJSON = Data(#"{"accent_phrases":[],"speedScale":1.0,"pitchScale":0}"#.utf8)
        let fake = FakeHTTPClient { url in
            url.path.contains("audio_query") ? queryJSON : Data("wav".utf8)
        }
        let tts = VoicevoxTTS(endpoint: "http://127.0.0.1:50021/", http: fake, speedScale: 1.15)

        _ = try await tts.synthesize(text: "テスト", speakerId: 3)

        let body = try JSONSerialization.jsonObject(with: fake.requests[1].body ?? Data()) as? [String: Any]
        #expect(body?["speedScale"] as? Double == 1.15)
        #expect(body?["pitchScale"] as? Int == 0)  // 他のフィールドは保持される
    }

    @Test func standardSpeedPassesQueryThroughUnmodified() async throws {
        let queryJSON = Data(#"{"accent_phrases":[],"speedScale":1.0}"#.utf8)
        let fake = FakeHTTPClient { url in
            url.path.contains("audio_query") ? queryJSON : Data("wav".utf8)
        }
        let tts = VoicevoxTTS(endpoint: "http://127.0.0.1:50021/", http: fake)  // 既定 1.0
        _ = try await tts.synthesize(text: "テスト", speakerId: 3)
        #expect(fake.requests[1].body == queryJSON)  // 無加工
    }

    @Test func normalizesWaveDashToProlongedSoundMark() {
        // VOICEVOX は「〜」(U+301C) /「～」(U+FF5E) を区切ってしまう → 長音「ー」(U+30FC) に正規化。
        #expect(VoicevoxTTS.normalizeForSpeech("あ\u{301C}し") == "あ\u{30FC}し")
        #expect(VoicevoxTTS.normalizeForSpeech("ですよ\u{FF5E}") == "ですよ\u{30FC}")
        #expect(VoicevoxTTS.normalizeForSpeech("そのまま") == "そのまま")  // 〜 が無ければ無変換
    }

    @Test func synthesisSendsNormalizedText() async throws {
        let fake = FakeHTTPClient { url in
            url.path.contains("audio_query") ? Data("{\"accent_phrases\":[]}".utf8) : Data("wav".utf8)
        }
        let tts = VoicevoxTTS(endpoint: "http://127.0.0.1:50021/", http: fake)
        _ = try await tts.synthesize(text: "あ\u{301C}し", speakerId: 8)
        // audio_query の text= は正規化後（あーし）になっている。
        let query = fake.requests[0].url.query ?? ""
        #expect(query.contains("text=") == true)
        #expect(query.contains("\u{301C}") == false)  // 波ダッシュは残っていない
        // URL エンコードを解いて長音が入っていることを確認。
        let components = URLComponents(url: fake.requests[0].url, resolvingAgainstBaseURL: false)
        let textValue = components?.queryItems?.first { $0.name == "text" }?.value
        #expect(textValue == "あ\u{30FC}し")
    }

    @Test func connectionFailureMapsToUnreachable() async {
        let fake = FakeHTTPClient { _ in throw URLError(.cannotConnectToHost) }
        let tts = VoicevoxTTS(endpoint: "http://127.0.0.1:50021/", http: fake)
        await #expect(throws: TtsError.unreachable) {
            try await tts.synthesize(text: "x", speakerId: 3)
        }
    }

    @Test func httpStatusErrorMapsToSynthesisFailed() async {
        let fake = FakeHTTPClient { _ in throw HTTPClientError.status(500) }
        let tts = VoicevoxTTS(endpoint: "http://127.0.0.1:50021/", http: fake)
        await #expect(throws: TtsError.synthesisFailed(String(describing: HTTPClientError.status(500)))) {
            try await tts.synthesize(text: "x", speakerId: 3)
        }
    }
}
