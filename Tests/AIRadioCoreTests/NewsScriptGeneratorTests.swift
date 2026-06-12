import Foundation
import Testing
import AIRadioCore

@Suite("NewsScriptGenerator")
struct NewsScriptGeneratorTests {
    @Test("プロンプトに素材・ペルソナ・長さ・禁止事項が入る")
    func promptContainsEssentials() {
        let request = NewsScriptGenerator.makeRequest(
            news: "見出しA。見出しB。",
            weather: "東京地方は晴れ。",
            persona: "低く落ち着いた声のニュースキャスター。",
            targetCharacters: 640,
            styleHint: "簡潔に"
        )
        #expect(request.prompt.contains("見出しA"))
        #expect(request.prompt.contains("東京地方は晴れ"))
        #expect(request.prompt.contains("640"))
        #expect(request.prompt.contains("768"))                       // 上限 = 1.2 倍
        #expect(request.prompt.contains("時刻や日付"))                  // 時報との二重化防止
        #expect(request.prompt.contains("「ニュースの時間です」"))
        #expect(request.prompt.contains("簡潔に"))
        #expect(request.system?.contains("ニュースキャスター") == true)
        #expect(request.system?.contains("低く落ち着いた声") == true)
        #expect(request.temperature == 0.6)
    }

    @Test("整形: マークダウン装飾と空行を除去して 1 本の原稿にする")
    func sanitizeStripsDecorations() throws {
        let raw = """
        # 本日のニュース

        - まず**最初の話題**です。続きの文。

        次の話題はこちらです。
        """
        let body = try NewsScriptGenerator.sanitize(raw)
        #expect(body == "本日のニュース まず最初の話題です。続きの文。 次の話題はこちらです。")
    }

    @Test("実質空の応答は E-LLM-EMPTY-RESPONSE-001")
    func sanitizeThrowsOnEmpty() {
        #expect(throws: LLMError.emptyResponse) {
            _ = try NewsScriptGenerator.sanitize("\n  \n## \n")
        }
    }
}
