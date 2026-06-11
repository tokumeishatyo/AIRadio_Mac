import Foundation
import Yams
import AIRadioCore

/// LLM 設定。本体（モデル等、`config/llm.yaml`）と機密（API キー、`config/llm.local.yaml`）の 2 ファイル構成。
public struct LlmConfig: Sendable, Equatable {
    public var provider: String
    public var model: String
    public var endpoint: String
    public var temperature: Double
    public var apiKey: String

    public init(provider: String, model: String, endpoint: String, temperature: Double, apiKey: String) {
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.temperature = temperature
        self.apiKey = apiKey
    }
}

/// `config/llm.yaml` + `config/llm.local.yaml` のローダ。
/// キー欠落（local ファイルなし / api_key 空 / サンプルのプレースホルダのまま）は fail-fast。
public enum LlmConfigLoader {
    private struct MainFile: Decodable {
        struct Llm: Decodable {
            let provider: String?
            let model: String?
            let endpoint: String?
            let temperature: Double?
        }
        let llm: Llm?
    }
    private struct LocalFile: Decodable {
        struct Llm: Decodable {
            let api_key: String?
        }
        let llm: Llm?
    }

    public static func load(mainYaml: String, localYaml: String?) throws -> LlmConfig {
        let main = try YAMLDecoder().decode(MainFile.self, from: mainYaml)
        guard let model = main.llm?.model, !model.isEmpty else {
            throw ConfigError.missingField("llm.model")
        }

        guard let localYaml else { throw LLMError.keyMissing }
        let local = try YAMLDecoder().decode(LocalFile.self, from: localYaml)
        let apiKey = (local.llm?.api_key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !apiKey.contains("PASTE") else {
            throw LLMError.keyMissing
        }

        return LlmConfig(
            provider: main.llm?.provider ?? "gemini",
            model: model,
            endpoint: main.llm?.endpoint ?? "https://generativelanguage.googleapis.com/",
            temperature: main.llm?.temperature ?? 0.9,
            apiKey: apiKey
        )
    }

    public static func load(path: String, localPath: String) throws -> LlmConfig {
        let mainYaml = try String(contentsOfFile: path, encoding: .utf8)
        let localYaml = try? String(contentsOfFile: localPath, encoding: .utf8)
        return try load(mainYaml: mainYaml, localYaml: localYaml)
    }
}
