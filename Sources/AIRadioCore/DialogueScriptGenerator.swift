import Foundation

/// テーマ + DJ ペルソナ + 確定済みの締め曲から会話台本を LLM 生成する。
/// 出力契約: 1 行 = `DJ名: セリフ`。登録 DJ 名で始まらない行は無視（マークダウン混入対策）。
/// S12: テーマは引数（プールから選択済みの値）、日付・季節コンテキストを注入、お便り読み上げ形式に対応。
public struct DialogueScriptGenerator: Sendable {
    private let llm: any LLMBackend
    private let temperature: Double

    public init(llm: any LLMBackend, temperature: Double = 0.9) {
        self.llm = llm
        self.temperature = temperature
    }

    public func generate(
        corner: CornerTemplate,
        djs: [DjProfile],
        song: TrackInfo,
        theme: String? = nil,
        dateContext: String = "",
        letter: ListenerLetter? = nil,
        greeting: String? = nil,
        guest: DjProfile? = nil
    ) async throws -> DialogueScript {
        let request = Self.makeRequest(
            corner: corner, djs: djs, song: song,
            theme: theme, dateContext: dateContext, letter: letter,
            greeting: greeting, guest: guest, temperature: temperature
        )
        let raw = try await llm.generate(request)
        return try Self.parse(raw, djs: djs)
    }

    // MARK: - プロンプト構築

    /// - Parameters:
    ///   - djs: 出演者（**順序付き・先頭＝メイン**）。メインが主導し、他は相槌・ツッコミ・応答で返す（仕様 s13.5 §6）。
    ///   - greeting: 冒頭コーナーのみ非 nil（時刻連動の挨拶語）。非 nil＝挨拶＋出演者紹介、nil＝挨拶抑制で即本題。
    public static func makeRequest(
        corner: CornerTemplate,
        djs: [DjProfile],
        song: TrackInfo,
        theme: String? = nil,
        dateContext: String = "",
        letter: ListenerLetter? = nil,
        greeting: String? = nil,
        guest: DjProfile? = nil,
        temperature: Double = 0.9
    ) -> LLMRequest {
        let selectedTheme = theme ?? corner.theme
        let names = djs.map(\.name).joined(separator: "」「")
        let main = djs.first?.name ?? names
        let profiles = djs
            .map { "- \($0.name): \($0.persona)" }
            .joined(separator: "\n")

        // フォールバック曲はタイトル不明（URI のみ）のことがある。その場合は曲名を捏造させず匿名で紹介させる。
        let songIntro: String
        if song.title.isEmpty {
            songIntro = "曲名を明かさず「この後の一曲」として曲振りして締める。曲名やアーティスト名を推測して言ってはいけない。"
        } else {
            songIntro = "「\(song.artist)」の「\(song.title)」を紹介して締める。"
        }
        let songInstruction: String
        if let letter {
            songInstruction = "コーナーの最後は、\(letter.radioName)さんからのリクエスト曲として、\(songIntro)"
        } else {
            songInstruction = "コーナーの最後は、テーマの余韻から自然に\(songIntro)"
        }

        var sections = ["ラジオコーナー「\(corner.title)」の会話台本を書いてください。"]
        if let letter {
            sections.append("""
            # リスナーからのお便り
            ラジオネーム: \(letter.radioName)
            \(letter.body)
            """)
        } else {
            sections.append("""
            # テーマ
            \(selectedTheme)
            """)
        }
        if !dateContext.isEmpty {
            sections.append("""
            # 今日の日付と季節
            \(dateContext)
            """)
        }

        var constraints = [
            "セリフの合計は \(corner.targetCharacters) 文字以上、\(corner.targetCharacters * 12 / 10) 文字以内（\(corner.targetMinutes) 分程度の会話）。短すぎる台本は不可。",
            "出力は台本のみ。1 行につき 1 つのセリフを「DJ名: セリフ」の形式で書く。",
            "DJ名は「\(names)」のみ。ナレーション、ト書き、見出し、記号装飾は書かない。",
            "進行はメイン「\(main)」が主導し、ほかの出演者は相槌・ツッコミ・応答で自然に返す。",
            "各 DJ は上記プロフィールにある自分の一人称・口調・語尾だけを使う。ある DJ の特徴的な語尾（例:「〜のだ」）を、その DJ 以外のセリフに混ぜてはいけない（とくにメインの語尾を他の出演者に伝染させない）。",
        ]
        // 冒頭コーナーのみ挨拶＋出演者紹介。それ以外は挨拶・自己紹介・番組名を抑制して即本題（仕様 s13.5 §6）。
        if let greeting {
            constraints.append("これは番組の最初のコーナー。メイン「\(main)」がまず「\(greeting)」とリスナーに挨拶し、番組名「ケイラボAIラジオ」と本日の出演者（「\(names)」）を紹介してから本題に入る。")
        } else {
            constraints.append("これは番組の途中のコーナー。挨拶・自己紹介・番組名の名乗りはせず、いきなり本題から始める。")
        }
        if let letter {
            constraints.append("メインがまず「ラジオネーム \(letter.radioName)さんからのお便り」と紹介し、本文をセリフとして自然に読み上げる。")
            constraints.append("読み上げのあと、出演者でお便りへの感想を話す（テーマ: \(selectedTheme)。脱線してよい）。")
        }
        if let guest {
            // ゲストコーナー（仕様 s14）: 正式な紹介はリード文が済ませている前提で、軽い挨拶から本題へ。
            constraints.append("これはゲストを迎えるコーナー。ゲスト「\(guest.name)」が冒頭で軽く挨拶し（番組名の名乗りや大げさな自己紹介は不要）、メイン「\(main)」の進行でテーマ「\(selectedTheme)」を会話する。")
            constraints.append("ゲスト「\(guest.name)」は「\(selectedTheme)」に詳しい専門家として、具体的なエピソードや豆知識を交えて語る。サブは相づち・質問で会話を回す。")
            constraints.append("コーナーの最後に、メインがゲスト「\(guest.name)」へお礼を述べてから曲を紹介する。")
        }
        if !dateContext.isEmpty {
            constraints.append("季節や時候の話は、上の日付・季節に合わせる。")
        }
        constraints.append(songInstruction)
        sections.append("# 制約\n" + constraints.map { "- \($0)" }.joined(separator: "\n"))

        let system = """
        あなたはラジオ番組「ケイラボAIラジオ」の放送作家です。
        リスナーが作業しながら聴ける、肩の力の抜けた楽しい会話を書きます。

        # 出演DJ
        \(profiles)
        """

        return LLMRequest(prompt: sections.joined(separator: "\n\n"), system: system, temperature: temperature)
    }

    /// アーティスト特集（仕様 s15）の発話パート別 LLM リクエスト。各パートを個別生成する。
    /// 曲名は与えられた表記をそのまま使わせる（プレフライト済みの実曲名と一致＝紹介と再生の不一致を防ぐ）。
    public static func makeArtistFeatureRequest(
        part: ArtistFeaturePart,
        artistName: String,
        djs: [DjProfile],
        dateContext: String = "",
        targetCharacters: Int,
        temperature: Double = 0.9
    ) -> LLMRequest {
        let names = djs.map(\.name).joined(separator: "」「")
        let main = djs.first?.name ?? names
        let profiles = djs.map { "- \($0.name): \($0.persona)" }.joined(separator: "\n")

        var sections: [String]
        var constraints: [String] = [
            "セリフの合計は \(targetCharacters) 文字以上、\(targetCharacters * 12 / 10) 文字以内。短すぎる台本は不可。",
            "出力は台本のみ。1 行につき 1 つのセリフを「DJ名: セリフ」の形式で書く。",
            "DJ名は「\(names)」のみ。ナレーション、ト書き、見出し、記号装飾は書かない。",
            "進行はメイン「\(main)」が主導し、ほかの出演者は相槌・ツッコミ・応答で自然に返す。",
            "各 DJ は上記プロフィールにある自分の一人称・口調・語尾だけを使う。ある DJ の特徴的な語尾（例:「〜のだ」）を、その DJ 以外のセリフに混ぜてはいけない（とくにメインの語尾を他の出演者に伝染させない）。",
            "これは番組の途中。挨拶・自己紹介・番組名の名乗りはせず、いきなり本題から始める。",
        ]
        switch part {
        case .intro:
            sections = ["ラジオ番組のアーティスト特集の「導入」の会話台本を書いてください。"]
            constraints.append("メイン「\(main)」が『ここからはアーティスト特集』と宣言し、本日特集するアーティスト「\(artistName)」への思いや好きなところを一言添える。")
            constraints.append("まだ曲名には触れない（曲の紹介は次のパートで行う）。")
        case .groupIntro(let tracks):
            let list = tracks.map { "「\($0.title)」（\($0.artist)）" }.joined(separator: "、")
            sections = ["ラジオ番組のアーティスト特集で、これから連続で流す \(tracks.count) 曲をまとめて紹介する会話台本を書いてください。"]
            sections.append("# 紹介する曲（この順で）\n\(list)")
            constraints.append("上の曲を順に紹介する。曲名・アーティスト名は与えられた表記を一字一句そのまま言い、言い換え・推測・別情報の捏造をしない。")
            constraints.append("各曲に聴きどころを軽く添え、最後は曲へ送り出して締める。")
        case .comment(let shorter):
            sections = ["ラジオ番組のアーティスト特集で、今流した曲を聴いたあとの感想・雑談の会話台本を書いてください。"]
            constraints.append(shorter
                ? "前の感想より短く、テンポよくまとめる。"
                : "出演者で曲やアーティストの感想を自由に話す（少し脱線してよい）。")
            constraints.append("次の曲紹介には踏み込まない（紹介は別パートで行う）。")
        }
        if !dateContext.isEmpty {
            sections.append("# 今日の日付と季節\n\(dateContext)")
            constraints.append("季節や時候の話に触れるなら、上の日付・季節に合わせる。")
        }
        sections.append("# 制約\n" + constraints.map { "- \($0)" }.joined(separator: "\n"))

        let system = """
        あなたはラジオ番組「ケイラボAIラジオ」の放送作家です。
        リスナーが作業しながら聴ける、肩の力の抜けた楽しい会話を書きます。

        # 出演DJ
        \(profiles)
        """
        return LLMRequest(prompt: sections.joined(separator: "\n\n"), system: system, temperature: temperature)
    }

    // MARK: - パース

    public static func parse(_ raw: String, djs: [DjProfile], minLines: Int = 4) throws -> DialogueScript {
        var lines: [DialogueLine] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if let line = parseLine(String(rawLine), djs: djs) {
                lines.append(line)
            }
        }
        guard lines.count >= minLines else {
            throw LLMError.scriptParseFailed("セリフが \(lines.count) 行しか取れませんでした（最低 \(minLines) 行）")
        }
        return DialogueScript(lines: lines)
    }

    private static func parseLine(_ rawLine: String, djs: [DjProfile]) -> DialogueLine? {
        // 行頭の装飾（箇条書き・強調・引用）を除去してから DJ 名を照合する。
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        while let first = line.first, "*-•>#".contains(first) {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        for dj in djs where line.hasPrefix(dj.name) {
            var rest = String(line.dropFirst(dj.name.count))
            // 「名前**: セリフ」のような強調の残りも許容する。
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            guard let separator = rest.first, separator == ":" || separator == "：" else { continue }
            let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return DialogueLine(djId: dj.id, text: text)
        }
        return nil
    }
}
