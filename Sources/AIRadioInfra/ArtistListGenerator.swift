import Foundation
import Yams
import AIRadioCore

/// アーティスト一覧の生成（メニュー「アーティスト一覧を生成」ボタンの共通処理。仕様 s15 §9-3）。
/// `artist-gen.yaml` の genre_prompt のジャンルで LLM に挙げさせ、Spotify 検索で実在検証し、
/// `config/artists.yaml` を原子的に上書きする（オフライン。音は出さない）。
public struct ArtistListGenerator: Sendable {
    private let llm: any LLMBackend
    private let catalog: any ArtistCatalog
    private let temperature: Double

    public init(llm: any LLMBackend, catalog: any ArtistCatalog, temperature: Double = 1.0) {
        self.llm = llm
        self.catalog = catalog
        self.temperature = temperature
    }

    /// 生成して `path`（config/artists.yaml）へ原子的に上書きする。返り値は確定した組数。
    /// 検証後 0 組なら `ArtistGenError.noResults` を投げ、ファイルは変更しない。
    @discardableResult
    public func generate(config: ArtistGenConfig, writingTo path: String, maxRetries: Int = 2) async throws -> Int {
        var seen = Set<String>()       // 正規化名で去重
        var entries: [(name: String, reading: String?)] = []   // 採用順（reading 付き。仕様 s19b）
        var attempt = 0
        while entries.count < config.targetCount && attempt <= maxRetries {
            attempt += 1
            try Task.checkCancellation()
            let want = config.targetCount - entries.count
            let request = Self.makeRequest(
                config: config, want: want, excluding: entries.map { $0.name }, temperature: temperature)
            let raw = (try? await llm.generate(request)) ?? ""
            var addedThisRound = 0
            for candidate in Self.parseEntries(raw) {
                if entries.count >= config.targetCount { break }
                let canonical = ArtistsConfigLoader.canonicalName(candidate.name)
                guard !canonical.isEmpty, seen.insert(canonical).inserted else { continue }
                // 実在検証: Spotify でその名前の曲が見つかるか（非実在・配信なし・ジャンル外を間引く）。
                try Task.checkCancellation()
                let tracks = (try? await catalog.topTracks(artistName: candidate.name, limit: 1)) ?? []
                guard !tracks.isEmpty else { continue }
                entries.append(candidate)
                addedThisRound += 1
            }
            if addedThisRound == 0 { break }   // これ以上増えない（LLM 枯渇）なら打ち切り
        }
        guard !entries.isEmpty else { throw ArtistGenError.noResults }

        let artists = entries.enumerated().map {
            ArtistProfile(
                id: String(format: "artist_%03d", $0.offset + 1),
                name: $0.element.name, reading: $0.element.reading)
        }
        try Self.write(artists, to: path)
        return artists.count
    }

    // MARK: - プロンプト / パース / 書き出し

    static func makeRequest(config: ArtistGenConfig, want: Int, excluding: [String], temperature: Double) -> LLMRequest {
        var prompt = """
        \(config.genrePrompt)
        上記に該当する音楽アーティスト（バンド・ソロ・グループ）を \(max(want, 1)) 組、できるだけ多く挙げてください。

        # 出力形式
        - 1 行につき 1 組。「アーティスト名」と「全角カタカナの読み」をタブ区切りで書く（例: 米津玄師\tヨネヅケンシ）。
        - 読みが分からなければ名前だけでもよい（タブと読みを省略）。
        - 番号・説明・装飾・補足は書かない。

        # 制約
        - 実在し、Spotify で配信されている可能性が高い有名どころを中心に。
        - 重複・別表記の重複を避ける。
        """
        if !excluding.isEmpty {
            // 既出を除く（リトライ時に重複を減らす）。長すぎないよう直近分のみ。
            let recent = excluding.suffix(80).joined(separator: "、")
            prompt += "\n- 次のアーティストは既出なので除く: \(recent)"
        }
        return LLMRequest(prompt: prompt, temperature: temperature)
    }

    /// 1 行を「名前<TAB>カタカナ読み」として解釈する（仕様 s19b §3.3）。
    /// タブ無しは名前のみ（reading=nil）で救済。読みは正規化＋カタカナ検証し、非カタカナなら捨てる。
    static func parseEntries(_ raw: String) -> [(name: String, reading: String?)] {
        raw.split(separator: "\n").compactMap { rawLine -> (name: String, reading: String?)? in
            // 最初のタブ区切りで分割（3 列目以降は無視）。
            let columns = String(rawLine).components(separatedBy: "\t")
            var name = columns[0].trimmingCharacters(in: .whitespaces)
            if let bullet = name.range(of: #"^(?:[-*•]\s+|\d+[.)]\s*)+"#, options: .regularExpression) {
                name.removeSubrange(bullet)
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'「」 　"))
            guard !name.isEmpty else { return nil }

            // 2 列目があれば読み候補。NFKC+NFC 正規化＋カタカナ検証。非カタカナ（ひらがな/漢字/英字/「不明」等）は捨てる。
            var reading: String?
            if columns.count > 1 {
                let candidate = VoicevoxUserDict.normalizePronunciation(
                    columns[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'「」 　")))
                if VoicevoxUserDict.isKatakana(candidate) { reading = candidate }
            }
            return (name, reading)
        }
    }

    /// YAML として原子的に書き出す（`atomically: true` = 一時ファイル → rename。crash 耐性）。
    static func write(_ artists: [ArtistProfile], to path: String) throws {
        struct Out: Encodable {
            struct A: Encodable {
                let id: String
                let name: String
                let reading: String?
                enum CodingKeys: String, CodingKey { case id, name, reading }
                func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encode(id, forKey: .id)
                    try c.encode(name, forKey: .name)
                    if let reading { try c.encode(reading, forKey: .reading) }   // nil は出力しない（仕様 s19b）
                }
            }
            let artists: [A]
        }
        let body = try YAMLEncoder().encode(
            Out(artists: artists.map { .init(id: $0.id, name: $0.name, reading: $0.reading) }))
        let header = "# アーティスト特集（仕様 s15）のプール。メニュー「アーティスト一覧を生成」が生成・上書きする。\n"
            + "# 手編集可（id は一意・name は必須・reading は任意のカタカナ読み 仕様 s19b）。ジャンル・件数は config/artist-gen.yaml で指定。\n"
        try (header + body).write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }
}

/// アーティスト生成（オフライン）のエラー。放送系の RadioError 体系には載せない（生成ツール固有）。
public enum ArtistGenError: Error, Equatable, CustomStringConvertible {
    case noResults
    public var description: String {
        "アーティストを生成できませんでした（LLM 応答が空、または実在検証で全滅）。"
    }
}
