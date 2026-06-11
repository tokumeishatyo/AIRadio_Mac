import Foundation
import Testing
import AIRadioCore
@testable import AIRadioInfra

private func okResponse(_ texts: [String]) -> Data {
    let parts = texts.map { ["text": $0] }
    let json: [String: Any] = ["candidates": [["content": ["parts": parts]]]]
    return try! JSONSerialization.data(withJSONObject: json)
}

@Suite("GeminiLLMBackend")
struct GeminiLLMBackendTests {
    private func makeBackend(_ http: FakeHTTPClient) -> GeminiLLMBackend {
        GeminiLLMBackend(
            endpoint: "https://generativelanguage.googleapis.com",
            model: "gemini-test",
            apiKey: "SECRET-KEY",
            http: http
        )
    }

    @Test("リクエスト: URL にモデル、キーはヘッダ、本文に prompt/system/temperature")
    func requestShape() async throws {
        let http = FakeHTTPClient { _ in okResponse(["こんにちは"]) }
        let backend = makeBackend(http)
        _ = try await backend.generate(LLMRequest(prompt: "P", system: "S", temperature: 0.5))

        let request = try #require(http.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString ==
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent")
        // キーは URL ではなくヘッダで送る（ログ・エラーに漏らさない）。
        #expect(!request.url.absoluteString.contains("SECRET-KEY"))
        #expect(request.headers["x-goog-api-key"] == "SECRET-KEY")

        let body = try JSONSerialization.jsonObject(with: #require(request.body)) as? [String: Any]
        let contents = body?["contents"] as? [[String: Any]]
        let parts = contents?.first?["parts"] as? [[String: Any]]
        #expect(parts?.first?["text"] as? String == "P")
        let system = body?["systemInstruction"] as? [String: Any]
        let systemParts = system?["parts"] as? [[String: Any]]
        #expect(systemParts?.first?["text"] as? String == "S")
        let generation = body?["generationConfig"] as? [String: Any]
        #expect(generation?["temperature"] as? Double == 0.5)
    }

    @Test("system なしのリクエストには systemInstruction を含めない")
    func omitsSystemInstruction() async throws {
        let http = FakeHTTPClient { _ in okResponse(["x"]) }
        _ = try await makeBackend(http).generate(LLMRequest(prompt: "P"))
        let body = try JSONSerialization.jsonObject(with: #require(http.requests.first?.body)) as? [String: Any]
        #expect(body?["systemInstruction"] == nil)
    }

    @Test("応答の parts を連結して返す")
    func joinsParts() async throws {
        let http = FakeHTTPClient { _ in okResponse(["前半", "後半"]) }
        let text = try await makeBackend(http).generate(LLMRequest(prompt: "P"))
        #expect(text == "前半後半")
    }

    @Test("テキストのない応答は E-LLM-EMPTY-RESPONSE-001")
    func emptyResponseThrows() async {
        let http = FakeHTTPClient { _ in Data("{}".utf8) }
        await #expect(throws: LLMError.emptyResponse) {
            _ = try await makeBackend(http).generate(LLMRequest(prompt: "P"))
        }
    }

    @Test("HTTP エラーは E-LLM-API-FAILED-001（ステータスのみ、キーは含めない）")
    func httpErrorThrows() async {
        let http = FakeHTTPClient { _ in throw HTTPClientError.status(429) }
        do {
            _ = try await makeBackend(http).generate(LLMRequest(prompt: "P"))
            Issue.record("エラーになるはず")
        } catch let error as LLMError {
            #expect(error == .apiFailed("HTTP 429"))
            #expect(!error.message.contains("SECRET-KEY"))
        } catch {
            Issue.record("LLMError 以外: \(error)")
        }
    }
}
