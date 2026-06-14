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

    // MARK: - S13.5: 主導/応答 + 冒頭挨拶の有無

    private let threeCast = [
        DjProfile(id: "tsumugi", name: "春日部つむぎ", speakerId: 8, persona: "あ〜し口調"),
        DjProfile(id: "zundamon", name: "ずんだもん", speakerId: 3, persona: "なのだ口調"),
        DjProfile(id: "metan", name: "四国めたん", speakerId: 2, persona: "ですわ口調"),
    ]

    @Test("先頭＝メインが主導し、他は相槌・ツッコミ・応答で返す指示が入る")
    func mainLeadsInstruction() {
        let song = TrackInfo(uri: "spotify:track:X", title: "曲", artist: "歌手")
        let request = DialogueScriptGenerator.makeRequest(corner: corner(), djs: threeCast, song: song)
        // cast 先頭の つむぎ がメイン。
        #expect(request.prompt.contains("メイン「春日部つむぎ」が主導"))
        #expect(request.prompt.contains("相槌・ツッコミ・応答"))
    }

    @Test("語尾の混線を禁止する指示が入る（メインの語尾を他の出演者に伝染させない、s15 fix）")
    func forbidsSpeechStyleBleed() {
        let song = TrackInfo(uri: "spotify:track:X", title: "曲", artist: "歌手")
        let request = DialogueScriptGenerator.makeRequest(corner: corner(), djs: threeCast, song: song)
        #expect(request.prompt.contains("自分の一人称・口調・語尾だけを使う"))
        #expect(request.prompt.contains("伝染させない"))
    }

    @Test("アーティスト特集パートも語尾の混線を禁止する（s15 fix）")
    func artistFeatureForbidsSpeechStyleBleed() {
        let request = DialogueScriptGenerator.makeArtistFeatureRequest(
            part: .intro, artistName: "米津玄師", djs: threeCast, targetCharacters: 200)
        #expect(request.prompt.contains("自分の一人称・口調・語尾だけを使う"))
        #expect(request.prompt.contains("伝染させない"))
    }

    // MARK: - S15 fix: グループ紹介の連続感・ラスト明示（会話の自然さ改善）

    private func featureTracks(_ n: Int) -> [TrackInfo] {
        (1...n).map { TrackInfo(uri: "spotify:track:T\($0)", title: "ソング\($0)", artist: "歌手") }
    }

    private func groupIntroRequest(index: Int, total: Int, tracks: Int = 3) -> LLMRequest {
        DialogueScriptGenerator.makeArtistFeatureRequest(
            part: .groupIntro(tracks: featureTracks(tracks), index: index, total: total),
            artistName: "米津玄師", djs: djs, targetCharacters: 320)
    }

    @Test("1 回目のグループ紹介（index 0・複数）: 連続感・ラスト指示は入らない（従来どおり）")
    func firstGroupIntroIsPlain() {
        let prompt = groupIntroRequest(index: 0, total: 3).prompt
        #expect(!prompt.contains("進行中"))
        #expect(!prompt.contains("引き続き"))
        #expect(!prompt.contains("最後"))
    }

    @Test("2 回目以降の中盤グループ紹介（index 1/total 3）: 進行中の特集を続けるつなぎ・新規開始の言い方を禁止")
    func middleGroupIntroHasContinuity() {
        let prompt = groupIntroRequest(index: 1, total: 3).prompt
        #expect(prompt.contains("進行中"))               // すでに進行中の特集
        #expect(prompt.contains("引き続き"))             // 「引き続き〇〇の曲を」のつなぎ
        #expect(prompt.contains("新しく始めるような言い方"))  // 「続いては〇〇特集」を禁止（fix2）
        #expect(prompt.contains("やり直さず"))
        #expect(!prompt.contains("最後"))
    }

    @Test("最後のグループ紹介（index 2/total 3）: 連続感＋ラスト明示（曲数入り）")
    func lastGroupIntroIsMarkedLast() {
        let prompt = groupIntroRequest(index: 2, total: 3, tracks: 1).prompt
        #expect(prompt.contains("引き続き"))               // 最後も 2 回目以降なので連続感は出す
        #expect(prompt.contains("最後である旨"))
        #expect(prompt.contains("最後はこの 1 曲"))         // 曲数に応じた文言
    }

    @Test("ラスト明示は曲数に応じる: K=5→[3,2] の最後 2 曲、K=6→[3,3] の最後 3 曲（縮約・index1/total2 経路）")
    func lastGroupMarkerMatchesTrackCount() {
        // 確定要件②「縮約で複数曲のこともあるので曲数に応じて」。最後グループが 1 曲でない経路を担保。
        let twoSongs = groupIntroRequest(index: 1, total: 2, tracks: 2).prompt
        #expect(twoSongs.contains("最後はこの 2 曲"))
        #expect(twoSongs.contains("引き続き"))             // index1=2 回目なので連続感も出す
        let threeSongs = groupIntroRequest(index: 1, total: 2, tracks: 3).prompt
        #expect(threeSongs.contains("最後はこの 3 曲"))
    }

    @Test("唯一のグループ紹介（index 0/total 1＝K3）: 1 回目扱い＝連続感もラスト指示も入らない")
    func singleGroupIntroIsPlain() {
        let prompt = groupIntroRequest(index: 0, total: 1).prompt
        #expect(!prompt.contains("進行中"))
        #expect(!prompt.contains("引き続き"))
        #expect(!prompt.contains("最後"))
    }

    @Test("greeting 非 nil（冒頭）: 時刻連動の挨拶＋番組名＋出演者紹介を指示")
    func greetingPromptForOpeningCorner() {
        let song = TrackInfo(uri: "spotify:track:X", title: "曲", artist: "歌手")
        let request = DialogueScriptGenerator.makeRequest(
            corner: corner(), djs: djs, song: song, greeting: "こんばんは")
        #expect(request.prompt.contains("番組の最初のコーナー"))
        #expect(request.prompt.contains("こんばんは"))
        #expect(request.prompt.contains("ケイラボAIラジオ"))
        #expect(request.prompt.contains("本日の出演者"))
        #expect(request.prompt.contains("今日の気分"))   // s16: 冒頭の会話のフリに今日の気分
        #expect(request.prompt.contains("具体的な時刻・時間帯は断定しない"))  // s17 fix: 「深夜」等の誤時刻を禁止
        #expect(!request.prompt.contains("挨拶・自己紹介・番組名の名乗りはせず"))
    }

    @Test("journalContext 非空（冒頭）: 前回の振り返りセクションと軽く触れる指示が入る（s18）")
    func journalContextInOpening() {
        let song = TrackInfo(uri: "spotify:track:X", title: "曲", artist: "歌手")
        let request = DialogueScriptGenerator.makeRequest(
            corner: corner(), djs: djs, song: song, greeting: "こんばんは",
            journalContext: "・ゲストにあんこもんさんを迎えました。")
        #expect(request.prompt.contains("前回までの番組の振り返り"))
        #expect(request.prompt.contains("あんこもん"))
        #expect(request.prompt.contains("軽く一言だけ触れて"))
    }

    @Test("journalContext 空（既定）: 振り返りセクションは入らない（s18）")
    func noJournalContextByDefault() {
        let song = TrackInfo(uri: "spotify:track:X", title: "曲", artist: "歌手")
        let request = DialogueScriptGenerator.makeRequest(
            corner: corner(), djs: djs, song: song, greeting: "こんばんは")
        #expect(!request.prompt.contains("前回までの番組の振り返り"))
    }

    @Test("greeting nil（既定・途中）: 挨拶・自己紹介・番組名を抑制して即本題")
    func noGreetingPromptForLaterCorner() {
        let song = TrackInfo(uri: "spotify:track:X", title: "曲", artist: "歌手")
        let request = DialogueScriptGenerator.makeRequest(corner: corner(), djs: djs, song: song)
        #expect(request.prompt.contains("挨拶・自己紹介・番組名の名乗りはせず、いきなり本題から始める"))
        #expect(!request.prompt.contains("番組の最初のコーナー"))
        #expect(!request.prompt.contains("今日の気分"))   // s16: 今日の気分は冒頭コーナーのみ
    }

    @Test("guest 非 nil: ゲスト挨拶・専門家フレーミング・お礼を指示し、ゲストを出演者に含める（s14）")
    func guestPromptFramesExpertAndThanks() {
        let song = TrackInfo(uri: "spotify:track:X", title: "曲", artist: "歌手")
        let guest = DjProfile(id: "sora", name: "九州そら", speakerId: 16, persona: "おっとり穏やか")
        // cast はメイン + ゲスト（末尾）。
        let cast = djs + [guest]
        let request = DialogueScriptGenerator.makeRequest(
            corner: corner(), djs: cast, song: song, theme: "スポーツ", guest: guest)
        #expect(request.prompt.contains("ゲストを迎えるコーナー"))
        #expect(request.prompt.contains("九州そら"))
        #expect(request.prompt.contains("スポーツ"))          // テーマに詳しい専門家
        #expect(request.prompt.contains("専門家"))
        #expect(request.prompt.contains("お礼"))
        #expect(request.system?.contains("おっとり穏やか") == true)  // ゲストの persona が出演者欄に
    }

    @Test("guest nil（既定）: ゲスト関連の指示は入らない")
    func noGuestPromptByDefault() {
        let song = TrackInfo(uri: "spotify:track:X", title: "曲", artist: "歌手")
        let request = DialogueScriptGenerator.makeRequest(corner: corner(), djs: djs, song: song)
        #expect(!request.prompt.contains("ゲストを迎えるコーナー"))
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
