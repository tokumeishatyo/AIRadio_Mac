import Foundation
import AIRadioCore

/// Gemini API（generateContent）で台本テキストを生成する `LLMBackend` 実装。
/// API キーは URL ではなく `x-goog-api-key` ヘッダで送る（ログ・エラーに漏れない、仕様 §3/§7）。
public struct GeminiLLMBackend: LLMBackend {
    private let endpoint: String
    private let model: String
    private let apiKey: String
    private let http: any HTTPClient

    public init(endpoint: String, model: String, apiKey: String, http: any HTTPClient) {
        self.endpoint = endpoint.hasSuffix("/") ? endpoint : endpoint + "/"
        self.model = model
        self.apiKey = apiKey
        self.http = http
    }

    public init(config: LlmConfig, http: any HTTPClient) {
        self.init(endpoint: config.endpoint, model: config.model, apiKey: config.apiKey, http: http)
    }

    public func generate(_ request: LLMRequest) async throws -> String {
        guard let url = URL(string: endpoint + "v1beta/models/\(model):generateContent") else {
            throw LLMError.apiFailed("エンドポイント URL が不正です")
        }
        let body = try JSONEncoder().encode(RequestBody(request))
        let data: Data
        do {
            data = try await http.post(url: url, body: body, headers: [
                "Content-Type": "application/json",
                "x-goog-api-key": apiKey,
            ])
        } catch let HTTPClientError.status(status) {
            throw LLMError.apiFailed("HTTP \(status)")
        } catch is URLError {
            throw LLMError.apiFailed("Gemini API に接続できません")
        }

        let response: ResponseBody
        do {
            response = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw LLMError.apiFailed("応答 JSON を解釈できません")
        }
        let text = (response.candidates?.first?.content?.parts ?? [])
            .compactMap(\.text)
            .joined()
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }

    // MARK: - API の JSON 形

    private struct Part: Codable {
        var text: String?
    }
    private struct Content: Codable {
        var role: String?
        var parts: [Part]?
    }
    private struct RequestBody: Encodable {
        struct GenerationConfig: Encodable {
            var temperature: Double
        }
        var contents: [Content]
        var systemInstruction: Content?
        var generationConfig: GenerationConfig

        init(_ request: LLMRequest) {
            contents = [Content(role: "user", parts: [Part(text: request.prompt)])]
            systemInstruction = request.system.map { Content(parts: [Part(text: $0)]) }
            generationConfig = GenerationConfig(temperature: request.temperature)
        }
    }
    private struct ResponseBody: Decodable {
        struct Candidate: Decodable {
            var content: Content?
        }
        var candidates: [Candidate]?
    }
}
