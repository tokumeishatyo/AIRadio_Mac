import Foundation
import Testing
import AIRadioCore
import AIRadioTestSupport
@testable import AIRadioInfra

@Suite("LlmNewsScriptProvider")
struct LlmNewsScriptProviderTests {
    private let style = NewsScriptStyle(
        styleHint: "簡潔に",
        intro: "時刻は{hour12}時{minute}分になりました。ニュースの時間です。",
        outro: "以上、ニュースと天気予報でした。"
    )

    private func makeProvider(llm: any LLMBackend) -> LlmNewsScriptProvider {
        LlmNewsScriptProvider(
            news: FakeResearchSource(payload: "見出しA。見出しB。"),
            weather: FakeResearchSource(payload: "東京地方は晴れ。"),
            llm: llm,
            persona: "ニュースキャスター",
            style: style,
            fallbackTemplate: "定型: {news} 天気: {weather}"
        )
    }

    @Test("成功時: 固定イントロ + LLM 本文 + 固定アウトロを組み立てる")
    func assemblesScript() async {
        let llm = ScriptedLLM(responses: ["まずは見出しAの話題です。いやはや驚きですね。"])
        let script = await makeProvider(llm: llm).announcement()
        #expect(script == "時刻は{hour12}時{minute}分になりました。ニュースの時間です。 まずは見出しAの話題です。いやはや驚きですね。 以上、ニュースと天気予報でした。")
        // LLM には素材が渡っている。
        #expect(llm.requests.first?.prompt.contains("見出しA") == true)
        #expect(llm.requests.first?.prompt.contains("東京地方は晴れ") == true)
    }

    @Test("LLM 失敗時は定型テンプレ原稿に倒す（放送継続）")
    func fallsBackToTemplateOnLlmFailure() async {
        let script = await makeProvider(llm: ScriptedLLM(responses: [])).announcement()
        #expect(script == "定型: 見出しA。見出しB。 天気: 東京地方は晴れ。")
    }

    @Test("素材の個別失敗はフォールバック文言で LLM へ渡す")
    func usesFallbackMaterialsOnSourceFailure() async {
        struct FailingSource: ResearchSource {
            func fetch() async throws -> String { throw ResearchError.newsFetchFailed("down") }
        }
        let llm = ScriptedLLM(responses: ["本文です。"])
        let provider = LlmNewsScriptProvider(
            news: FailingSource(),
            weather: FakeResearchSource(payload: "晴れ。"),
            llm: llm,
            persona: "",
            style: style,
            fallbackTemplate: "定型: {news}"
        )
        _ = await provider.announcement()
        #expect(llm.requests.first?.prompt.contains("本日のニュースは準備中です。") == true)
    }
}
