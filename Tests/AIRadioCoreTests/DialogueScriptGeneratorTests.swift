import Foundation
import Testing
import AIRadioCore
import AIRadioTestSupport

private let zundamon = DjProfile(id: "zundamon", name: "ずんだもん", speakerId: 3, persona: "語尾は「なのだ」")
private let metan = DjProfile(id: "metan", name: "四国めたん", speakerId: 2, persona: "上品な口調")
private let djs = [zundamon, metan]

private func corner(playSeconds: Int = 60) -> CornerTemplate {
    CornerTemplate(
        id: "free_talk",
        title: "フリートーク",
        theme: "最近気になっていること",
        djIds: ["zundamon", "metan"],
        targetMinutes: 5,
        charsPerMinute: 320,
        songPromptHint: "落ち着いた曲",
        fallbackTrackUri: "spotify:track:FALLBACK",
        volume: 85,
        playSeconds: playSeconds
    )
}

@Suite("DialogueScriptGenerator: パース")
struct DialogueScriptParseTests {
    @Test("基本形式（半角・全角コロン混在）をパースする")
    func parsesBasicFormat() throws {
        let raw = """
        ずんだもん: こんにちはなのだ。
        四国めたん：ごきげんよう。
        ずんだもん: 今日のテーマはこれなのだ。
        四国めたん: 楽しみですわね。
        """
        let script = try DialogueScriptGenerator.parse(raw, djs: djs)
        #expect(script.lines.count == 4)
        #expect(script.lines[0] == DialogueLine(djId: "zundamon", text: "こんにちはなのだ。"))
        #expect(script.lines[1] == DialogueLine(djId: "metan", text: "ごきげんよう。"))
    }

    @Test("マークダウン装飾と無関係な行を無視する")
    func ignoresDecorationsAndUnknownLines() throws {
        let raw = """
        # フリートーク台本
        - **ずんだもん**: 装飾付きなのだ。
        ナレーション: これは無視される。
        * 四国めたん: 箇条書きですわ。
        ずんだもん: ふつうの行なのだ。
        （ここで BGM）
        四国めたん: おしまいですわ。
        """
        let script = try DialogueScriptGenerator.parse(raw, djs: djs)
        #expect(script.lines.count == 4)
        #expect(script.lines[0] == DialogueLine(djId: "zundamon", text: "装飾付きなのだ。"))
        #expect(script.lines[1] == DialogueLine(djId: "metan", text: "箇条書きですわ。"))
    }

    @Test("4 行未満は E-LLM-SCRIPT-PARSE-FAILED-001")
    func tooFewLinesThrows() {
        let raw = """
        ずんだもん: 一行目なのだ。
        四国めたん: 二行目ですわ。
        """
        #expect(throws: LLMError.self) {
            try DialogueScriptGenerator.parse(raw, djs: djs)
        }
        do {
            _ = try DialogueScriptGenerator.parse(raw, djs: djs)
        } catch let error as LLMError {
            #expect(error.code == "E-LLM-SCRIPT-PARSE-FAILED-001")
        } catch {
            Issue.record("LLMError 以外: \(error)")
        }
    }
}

@Suite("DialogueScriptGenerator: プロンプト")
struct DialogueScriptPromptTests {
    @Test("テーマ・目標文字数・DJ 名・曲名がプロンプトに入る")
    func promptContainsEssentials() {
        let song = TrackInfo(uri: "spotify:track:X", title: "夜に駆ける", artist: "YOASOBI")
        let request = DialogueScriptGenerator.makeRequest(corner: corner(), djs: djs, song: song, temperature: 0.8)
        #expect(request.prompt.contains("最近気になっていること"))
        #expect(request.prompt.contains("1600"))
        #expect(request.prompt.contains("ずんだもん"))
        #expect(request.prompt.contains("四国めたん"))
        #expect(request.prompt.contains("夜に駆ける"))
        #expect(request.prompt.contains("YOASOBI"))
        #expect(request.system?.contains("語尾は「なのだ」") == true)
        #expect(request.temperature == 0.8)
    }

    @Test("曲名不明（フォールバック曲）なら匿名紹介を指示し、曲名を要求しない")
    func anonymousSongInstructionWhenTitleUnknown() {
        let song = TrackInfo(uri: "spotify:track:FALLBACK", title: "", artist: "")
        let request = DialogueScriptGenerator.makeRequest(corner: corner(), djs: djs, song: song)
        #expect(request.prompt.contains("曲名を明かさず"))
        #expect(!request.prompt.contains("「」"))
    }

    @Test("theme 引数がテンプレ固定の theme より優先される（s12: プール選択テーマ）")
    func explicitThemeOverridesTemplate() {
        let song = TrackInfo(uri: "spotify:track:X", title: "曲", artist: "歌手")
        let request = DialogueScriptGenerator.makeRequest(
            corner: corner(), djs: djs, song: song, theme: "旅行・おでかけ")
        #expect(request.prompt.contains("旅行・おでかけ"))
        #expect(!request.prompt.contains("最近気になっていること"))
    }

    @Test("dateContext を渡すと日付・季節セクションと整合制約が入る（s12）")
    func dateContextInjectsSeasonSectionAndConstraint() {
        let song = TrackInfo(uri: "spotify:track:X", title: "曲", artist: "歌手")
        let request = DialogueScriptGenerator.makeRequest(
            corner: corner(), djs: djs, song: song,
            dateContext: "今日は6月12日、梅雨の時期です。")
        #expect(request.prompt.contains("今日は6月12日、梅雨の時期です。"))
        #expect(request.prompt.contains("季節や時候の話は、上の日付・季節に合わせる"))
    }

    @Test("dateContext なし（既定）では季節セクションを入れない")
    func noSeasonSectionWithoutDateContext() {
        let song = TrackInfo(uri: "spotify:track:X", title: "曲", artist: "歌手")
        let request = DialogueScriptGenerator.makeRequest(corner: corner(), djs: djs, song: song)
        #expect(!request.prompt.contains("日付と季節"))
    }

    @Test("letter: お便り全文・ラジオネーム紹介・リクエスト曲としての曲振りを指示する（s12 §3）")
    func letterPromptContainsLetterAndRequestInstruction() {
        let song = TrackInfo(uri: "spotify:track:X", title: "夜に駆ける", artist: "YOASOBI")
        let letter = ListenerLetter(radioName: "雨宿りのカエル", body: "梅雨の散歩で紫陽花を見つけました。")
        let request = DialogueScriptGenerator.makeRequest(
            corner: corner(), djs: djs, song: song,
            theme: "季節の楽しみ", dateContext: "今日は6月12日、梅雨の時期です。", letter: letter)
        #expect(request.prompt.contains("雨宿りのカエル"))
        #expect(request.prompt.contains("梅雨の散歩で紫陽花を見つけました。"))
        #expect(request.prompt.contains("お便り"))
        #expect(request.prompt.contains("リクエスト曲"))
        #expect(request.prompt.contains("夜に駆ける"))
        #expect(request.prompt.contains("感想"))
    }
}

@Suite("DialogueScriptGenerator: 生成")
struct DialogueScriptGenerateTests {
    @Test("LLM 応答を台本にして返す")
    func generatesScript() async throws {
        let llm = ScriptedLLM(responses: [
            """
            ずんだもん: こんにちはなのだ。
            四国めたん: ごきげんよう。
            ずんだもん: 今日も話すのだ。
            四国めたん: 最後はこの曲ですわ。
            """
        ])
        let generator = DialogueScriptGenerator(llm: llm, temperature: 0.9)
        let song = TrackInfo(uri: "spotify:track:X", title: "曲", artist: "アーティスト")
        let script = try await generator.generate(corner: corner(), djs: djs, song: song)
        #expect(script.lines.count == 4)
        #expect(llm.requests.count == 1)
    }
}
