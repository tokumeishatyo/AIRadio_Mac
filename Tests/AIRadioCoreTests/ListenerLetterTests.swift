import Foundation
import Testing
import AIRadioCore
import AIRadioTestSupport

@Suite("ListenerLetterGenerator: プロンプト")
struct ListenerLetterPromptTests {
    @Test("テーマ・日付季節コンテキスト・出力契約がプロンプトに入る")
    func promptContainsEssentials() {
        let request = ListenerLetterGenerator.makeRequest(
            theme: "旅行・おでかけ",
            dateContext: "今日は6月12日、梅雨の時期です。",
            temperature: 0.8
        )
        #expect(request.prompt.contains("旅行・おでかけ"))
        #expect(request.prompt.contains("今日は6月12日、梅雨の時期です。"))
        #expect(request.prompt.contains("ラジオネーム"))
        #expect(request.prompt.contains("季節や時候の話は、上の日付・季節に合わせる"))
        #expect(request.temperature == 0.8)
    }
}

@Suite("ListenerLetterGenerator: パース")
struct ListenerLetterParseTests {
    @Test("1 行目 = ラジオネーム、2 行目以降 = 本文")
    func parsesBasicFormat() throws {
        let letter = try ListenerLetterGenerator.parse("""
        ずんだ餅大好き
        先日、雨の合間に近所の公園へ散歩に行きました。
        紫陽花がきれいに咲いていて、梅雨も悪くないなと思いました。
        """)
        #expect(letter.radioName == "ずんだ餅大好き")
        #expect(letter.body == "先日、雨の合間に近所の公園へ散歩に行きました。\n紫陽花がきれいに咲いていて、梅雨も悪くないなと思いました。")
    }

    @Test("「ラジオネーム:」ラベルと装飾を除去する")
    func stripsLabelAndDecorations() throws {
        let letter = try ListenerLetterGenerator.parse("""
        **ラジオネーム: 雨宿りのカエル**
        - こんにちは。毎週楽しく聴いています。
        """)
        #expect(letter.radioName == "雨宿りのカエル")
        #expect(letter.body == "こんにちは。毎週楽しく聴いています。")
    }

    @Test("本文が空なら E-LLM-SCRIPT-PARSE-FAILED-001")
    func emptyBodyThrows() {
        do {
            _ = try ListenerLetterGenerator.parse("ラジオネームだけ")
            Issue.record("エラーになるはず")
        } catch let error as LLMError {
            #expect(error.code == "E-LLM-SCRIPT-PARSE-FAILED-001")
        } catch {
            Issue.record("LLMError 以外: \(error)")
        }
        #expect(throws: LLMError.self) { _ = try ListenerLetterGenerator.parse("") }
    }
}

@Suite("ListenerLetterGenerator: 生成")
struct ListenerLetterGenerateTests {
    @Test("LLM 応答をお便りにして返す")
    func generatesLetter() async throws {
        let llm = ScriptedLLM(responses: ["梅雨の散歩人\n雨の日の楽しみを見つけました。"])
        let generator = ListenerLetterGenerator(llm: llm, temperature: 0.9)
        let letter = try await generator.generate(theme: "季節の楽しみ", dateContext: "今日は6月12日、梅雨の時期です。")
        #expect(letter == ListenerLetter(radioName: "梅雨の散歩人", body: "雨の日の楽しみを見つけました。"))
        #expect(llm.requests.count == 1)
        #expect(llm.requests[0].prompt.contains("季節の楽しみ"))
    }
}
