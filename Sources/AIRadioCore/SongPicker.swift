import Foundation

/// コーナーの締め曲を決める。LLM にテーマに合う候補曲を挙げさせ、
/// プレフライト（検索 + 再生可否）で最初に再生可能な曲を確定する（CLAUDE.md §3-2）。
/// 全滅・検索不調の場合はテンプレートの `fallback_track_uri` に倒す（曲名不明のまま返す）。
public struct SongPicker: Sendable {
    public static let maxCandidates = 5

    private let llm: any LLMBackend
    private let searcher: any TrackSearcher
    private let temperature: Double

    public init(llm: any LLMBackend, searcher: any TrackSearcher, temperature: Double = 0.9) {
        self.llm = llm
        self.searcher = searcher
        self.temperature = temperature
    }

    public func pick(corner: CornerTemplate) async throws -> TrackInfo {
        let raw = try await llm.generate(Self.makeRequest(corner: corner, temperature: temperature))
        for candidate in Self.parseCandidates(raw).prefix(Self.maxCandidates) {
            // 候補単位の検索失敗は握り潰して次の候補へ（fail-tolerant）。
            let results = (try? await searcher.search(
                query: "\(candidate.title) \(candidate.artist)", limit: 3
            )) ?? []
            if let track = results.first(where: { $0.isPlayable }) {
                return track
            }
        }
        return TrackInfo(uri: corner.fallbackTrackUri, title: "", artist: "")
    }

    // MARK: - プロンプト構築

    public static func makeRequest(corner: CornerTemplate, temperature: Double = 0.9) -> LLMRequest {
        var prompt = """
        ラジオコーナー「\(corner.title)」（テーマ: \(corner.theme)）の締めにかける曲の候補を \(maxCandidates) 曲挙げてください。

        # 制約
        - 出力は 1 行につき 1 曲、「曲名 - アーティスト名」の形式のみ。番号・説明・装飾は書かない。
        - 実在する曲だけを挙げる（Spotify で配信されている可能性が高いもの）。
        """
        if !corner.songPromptHint.isEmpty {
            prompt += "\n- 選曲のヒント: \(corner.songPromptHint)"
        }
        return LLMRequest(prompt: prompt, temperature: temperature)
    }

    // MARK: - パース

    /// `曲名 - アーティスト名` 形式の行を抽出する。番号・箇条書きの前置きは許容、形式外の行は捨てる。
    public static func parseCandidates(_ raw: String) -> [(title: String, artist: String)] {
        raw.split(separator: "\n").compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // 行頭の箇条書き記号・番号（"- " "* " "1. " "2) " など）を除去。
            if let bullet = line.range(of: #"^(?:[-*•]\s+|\d+[.)]\s*)+"#, options: .regularExpression) {
                line.removeSubrange(bullet)
            }
            guard let range = line.range(of: " - ") else { return nil }
            let title = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let artist = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, !artist.isEmpty else { return nil }
            return (title, artist)
        }
    }
}
