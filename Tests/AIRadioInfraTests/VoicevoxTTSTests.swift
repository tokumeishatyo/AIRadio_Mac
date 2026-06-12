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
