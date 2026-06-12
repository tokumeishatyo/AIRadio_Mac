import Foundation

/// ニュース素材（見出し・天気）からアナウンサー原稿の**本文**を LLM 生成するための純粋ロジック（S11）。
/// 時報イントロ・締めのアウトロは固定文（正確性が必要）のため LLM に書かせない。
public enum NewsScriptGenerator {
    public static func makeRequest(
        news: String,
        weather: String,
        persona: String,
        targetCharacters: Int,
        styleHint: String = "",
        temperature: Double = 0.6
    ) -> LLMRequest {
        var constraints = """
        - 出力は読み上げる本文のみ。見出しの番号、記号装飾、ナレーション指示は書かない。
        - 各ニュースを自然な語りでつなぎ、ところどころに短いコメントをひとこと添える。
        - 天気予報にも一言添える。
        - 挨拶、時刻や日付、「ニュースの時間です」「以上です」などの定型句は書かない（前後に固定文があるため）。
        - 合計 \(targetCharacters) 文字以上、\(targetCharacters * 12 / 10) 文字以内。
        """
        if !styleHint.isEmpty {
            constraints += "\n- 語りのスタイル: \(styleHint)"
        }

        let prompt = """
        以下の素材から、ラジオで読み上げるニュース原稿の本文を書いてください。

        # 本日のニュース見出し
        \(news)

        # 天気予報
        \(weather)

        # 制約
        \(constraints)
        """

        let system = """
        あなたはラジオ番組「ケイラボAIラジオ」のニュースキャスターです。
        \(persona)
        """

        return LLMRequest(prompt: prompt, system: system, temperature: temperature)
    }

    /// 生成結果の整形: マークダウン見出し・装飾・空行を除去。実質空なら `E-LLM-EMPTY-RESPONSE-001`。
    public static func sanitize(_ raw: String) throws -> String {
        let lines = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                while let first = text.first, "#*->•".contains(first) {
                    text.removeFirst()
                    text = text.trimmingCharacters(in: .whitespaces)
                }
                return text.replacingOccurrences(of: "**", with: "")
            }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw LLMError.emptyResponse }
        return lines.joined(separator: " ")
    }
}
