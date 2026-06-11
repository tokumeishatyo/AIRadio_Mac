import Foundation

/// テーマ + DJ ペルソナ + 確定済みの締め曲から会話台本を LLM 生成する。
/// 出力契約: 1 行 = `DJ名: セリフ`。登録 DJ 名で始まらない行は無視（マークダウン混入対策）。
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
        song: TrackInfo
    ) async throws -> DialogueScript {
        let request = Self.makeRequest(corner: corner, djs: djs, song: song, temperature: temperature)
        let raw = try await llm.generate(request)
        return try Self.parse(raw, djs: djs)
    }

    // MARK: - プロンプト構築

    public static func makeRequest(
        corner: CornerTemplate,
        djs: [DjProfile],
        song: TrackInfo,
        temperature: Double = 0.9
    ) -> LLMRequest {
        let names = djs.map(\.name).joined(separator: "」「")
        let profiles = djs
            .map { "- \($0.name): \($0.persona)" }
            .joined(separator: "\n")

        // フォールバック曲はタイトル不明（URI のみ）のことがある。その場合は曲名を捏造させず匿名で紹介させる。
        let songInstruction: String
        if song.title.isEmpty {
            songInstruction = "コーナーの最後は、曲名を明かさず「この後の一曲」としてテーマの余韻から自然に曲振りして締める。曲名やアーティスト名を推測して言ってはいけない。"
        } else {
            songInstruction = "コーナーの最後は、テーマの余韻から自然に「\(song.artist)」の「\(song.title)」を紹介して締める。"
        }

        let prompt = """
        ラジオコーナー「\(corner.title)」の会話台本を書いてください。

        # テーマ
        \(corner.theme)

        # 制約
        - 合計でおよそ \(corner.targetCharacters) 文字（\(corner.targetMinutes) 分程度の会話）。
        - 出力は台本のみ。1 行につき 1 つのセリフを「DJ名: セリフ」の形式で書く。
        - DJ名は「\(names)」のみ。ナレーション、ト書き、見出し、記号装飾は書かない。
        - 二人が交互に、それぞれの口調を守って自然に会話する。
        - \(songInstruction)
        """

        let system = """
        あなたはラジオ番組「ケイラボAIラジオ」の放送作家です。
        リスナーが作業しながら聴ける、肩の力の抜けた楽しい会話を書きます。

        # 出演DJ
        \(profiles)
        """

        return LLMRequest(prompt: prompt, system: system, temperature: temperature)
    }

    // MARK: - パース

    public static func parse(_ raw: String, djs: [DjProfile]) throws -> DialogueScript {
        var lines: [DialogueLine] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if let line = parseLine(String(rawLine), djs: djs) {
                lines.append(line)
            }
        }
        guard lines.count >= 4 else {
            throw LLMError.scriptParseFailed("セリフが \(lines.count) 行しか取れませんでした")
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
