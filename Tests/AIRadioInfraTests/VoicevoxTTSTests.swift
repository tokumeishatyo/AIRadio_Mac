import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

/// テスト用の HTTP fake（リクエストを記録し、URL に応じた応答を返す/投げる）。
private final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let body: Data?
        let headers: [String: String]
    }
    private let lock = NSLock()
    private var _requests: [Request] = []
    var requests: [Request] { lock.withLock { _requests } }

    private let responder: @Sendable (URL) throws -> Data
    init(responder: @escaping @Sendable (URL) throws -> Data) {
        self.responder = responder
    }

    func post(url: URL, body: Data?, headers: [String: String]) async throws -> Data {
        lock.withLock { _requests.append(.init(url: url, body: body, headers: headers)) }
        return try responder(url)
    }
    func get(url: URL, headers: [String: String]) async throws -> Data {
        lock.withLock { _requests.append(.init(url: url, body: nil, headers: headers)) }
        return try responder(url)
    }
}

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
