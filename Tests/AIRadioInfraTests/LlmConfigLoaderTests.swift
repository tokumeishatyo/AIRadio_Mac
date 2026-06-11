import Foundation
import Testing
import AIRadioCore
@testable import AIRadioInfra

private let mainYaml = """
llm:
  provider: gemini
  model: "gemini-test"
  endpoint: "https://example.com/"
  temperature: 0.7
"""

@Suite("LlmConfigLoader")
struct LlmConfigLoaderTests {
    @Test("本体 + ローカル（キー）を合成して読み込む")
    func loadsBoth() throws {
        let config = try LlmConfigLoader.load(mainYaml: mainYaml, localYaml: "llm:\n  api_key: \"KEY123\"\n")
        #expect(config == LlmConfig(
            provider: "gemini",
            model: "gemini-test",
            endpoint: "https://example.com/",
            temperature: 0.7,
            apiKey: "KEY123"
        ))
    }

    @Test("provider / endpoint / temperature は省略時に既定値")
    func appliesDefaults() throws {
        let config = try LlmConfigLoader.load(
            mainYaml: "llm:\n  model: \"m\"\n",
            localYaml: "llm:\n  api_key: \"K\"\n"
        )
        #expect(config.provider == "gemini")
        #expect(config.endpoint == "https://generativelanguage.googleapis.com/")
        #expect(config.temperature == 0.9)
    }

    @Test("model 欠落は設定エラー（fail-fast）")
    func missingModelThrows() {
        #expect(throws: ConfigError.missingField("llm.model")) {
            _ = try LlmConfigLoader.load(mainYaml: "llm:\n  provider: gemini\n", localYaml: "llm:\n  api_key: \"K\"\n")
        }
    }

    @Test("ローカルファイルなしは E-LLM-KEY-MISSING-001")
    func missingLocalFileThrows() {
        #expect(throws: LLMError.keyMissing) {
            _ = try LlmConfigLoader.load(mainYaml: mainYaml, localYaml: nil)
        }
    }

    @Test("api_key が空・プレースホルダのままなら E-LLM-KEY-MISSING-001")
    func emptyOrPlaceholderKeyThrows() {
        #expect(throws: LLMError.keyMissing) {
            _ = try LlmConfigLoader.load(mainYaml: mainYaml, localYaml: "llm:\n  api_key: \"\"\n")
        }
        #expect(throws: LLMError.keyMissing) {
            _ = try LlmConfigLoader.load(
                mainYaml: mainYaml,
                localYaml: "llm:\n  api_key: \"PASTE-YOUR-GEMINI-API-KEY-HERE\"\n"
            )
        }
    }

    @Test("キー欠落のエラーメッセージにキー値・URL を含まない（案内のみ）")
    func keyMissingMessageIsSafe() {
        let message = LLMError.keyMissing.message
        #expect(message.contains("llm.local.yaml"))
    }
}
