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
        var names: [String] = []
        var attempt = 0
        while names.count < config.targetCount && attempt <= maxRetries {
            attempt += 1
            try Task.checkCancellation()
            let want = config.targetCount - names.count
            let request = Self.makeRequest(config: config, want: want, excluding: names, temperature: temperature)
            let raw = (try? await llm.generate(request)) ?? ""
            var addedThisRound = 0
            for candidate in Self.parseNames(raw) {
                if names.count >= config.targetCount { break }
                let canonical = ArtistsConfigLoader.canonicalName(candidate)
                guard !canonical.isEmpty, seen.insert(canonical).inserted else { continue }
                // 実在検証: Spotify でその名前の曲が見つかるか（非実在・配信なし・ジャンル外を間引く）。
                try Task.checkCancellation()
                let tracks = (try? await catalog.topTracks(artistName: candidate, limit: 1)) ?? []
                guard !tracks.isEmpty else { continue }
                names.append(candidate)
                addedThisRound += 1
            }
            if addedThisRound == 0 { break }   // これ以上増えない（LLM 枯渇）なら打ち切り
        }
        guard !names.isEmpty else { throw ArtistGenError.noResults }

        let artists = names.enumerated().map {
            ArtistProfile(id: String(format: "artist_%03d", $0.offset + 1), name: $0.element)
        }
        try Self.write(artists, to: path)
        return artists.count
    }

    // MARK: - プロンプト / パース / 書き出し

    static func makeRequest(config: ArtistGenConfig, want: Int, excluding: [String], temperature: Double) -> LLMRequest {
        var prompt = """
        \(config.genrePrompt)
        上記に該当する音楽アーティスト（バンド・ソロ・グループ）を \(max(want, 1)) 組、できるだけ多く挙げてください。

        # 制約
        - 出力は 1 行につき 1 組、「アーティスト名」のみ。番号・説明・装飾・補足は書かない。
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

    static func parseNames(_ raw: String) -> [String] {
        raw.split(separator: "\n").compactMap { rawLine -> String? in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let bullet = line.range(of: #"^(?:[-*•]\s+|\d+[.)]\s*)+"#, options: .regularExpression) {
                line.removeSubrange(bullet)
            }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'「」 　"))
            return line.isEmpty ? nil : line
        }
    }

    /// YAML として原子的に書き出す（`atomically: true` = 一時ファイル → rename。crash 耐性）。
    static func write(_ artists: [ArtistProfile], to path: String) throws {
        struct Out: Encodable {
            struct A: Encodable { let id: String; let name: String }
            let artists: [A]
        }
        let body = try YAMLEncoder().encode(Out(artists: artists.map { .init(id: $0.id, name: $0.name) }))
        let header = "# アーティスト特集（仕様 s15）のプール。メニュー「アーティスト一覧を生成」が生成・上書きする。\n"
            + "# 手編集可（id は一意・name は必須）。ジャンル・件数は config/artist-gen.yaml で指定。\n"
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
