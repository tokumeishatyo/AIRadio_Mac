import Foundation

/// 架空のリスナーからのお便り（仕様 s12 §3）。
public struct ListenerLetter: Sendable, Equatable {
    public var radioName: String
    public var body: String

    public init(radioName: String, body: String) {
        self.radioName = radioName
        self.body = body
    }
}

/// お便りコーナー用に、架空リスナーのお便りを LLM 生成する。
/// 出力契約: 1 行目 = ラジオネーム、2 行目以降 = 本文。装飾は除去、本文空ならパース失敗。
public struct ListenerLetterGenerator: Sendable {
    private let llm: any LLMBackend
    private let temperature: Double

    public init(llm: any LLMBackend, temperature: Double = 0.9) {
        self.llm = llm
        self.temperature = temperature
    }

    public func generate(theme: String, dateContext: String) async throws -> ListenerLetter {
        let raw = try await llm.generate(Self.makeRequest(theme: theme, dateContext: dateContext, temperature: temperature))
        return try Self.parse(raw)
    }

    // MARK: - プロンプト構築

    public static func makeRequest(theme: String, dateContext: String, temperature: Double = 0.9) -> LLMRequest {
        let prompt = """
        ラジオ番組「ケイラボAIラジオ」に届いた、架空のリスナーからのお便りを 1 通書いてください。

        # テーマ
        \(theme)

        # 今日の日付と季節
        \(dateContext)

        # 制約
        - 1 行目はラジオネーム（ペンネーム）のみを書く。
        - 2 行目以降にお便りの本文を書く（200 文字以上、400 文字以内。テーマにまつわる日常の出来事・気づき・ちょっとした相談など）。
        - 季節や時候の話は、上の日付・季節に合わせる。
        - 出力はお便りのみ。見出し、説明、記号装飾は書かない。
        """
        return LLMRequest(prompt: prompt, temperature: temperature)
    }

    // MARK: - パース

    public static func parse(_ raw: String) throws -> ListenerLetter {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { strip(String($0)) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            throw LLMError.scriptParseFailed("お便りが空です")
        }
        var radioName = lines.removeFirst()
        // 「ラジオネーム: ◯◯」のラベル付き出力も許容する。
        for label in ["ラジオネーム", "ラジオネーム名"] where radioName.hasPrefix(label) {
            let rest = radioName.dropFirst(label.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
            if !rest.isEmpty { radioName = rest }
        }
        let body = lines.joined(separator: "\n")
        guard !body.isEmpty else {
            throw LLMError.scriptParseFailed("お便りの本文が空です")
        }
        return ListenerLetter(radioName: radioName, body: body)
    }

    /// 行頭の装飾（箇条書き・強調・引用）と前後の強調記号を除去する。
    private static func strip(_ rawLine: String) -> String {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        while let first = line.first, "*-•>#".contains(first) {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        return line.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
    }
}
