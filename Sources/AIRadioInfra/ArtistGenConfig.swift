import Foundation
import Yams
import AIRadioCore

/// アーティスト特集の生成設定（`config/artist-gen.yaml`。仕様 s15 §9）。
/// メニューの「アーティスト一覧を生成」ボタンが読む入力。ジャンル・件数をハードコードせずここで変える。
/// （これは入力。生成結果は config/artists.yaml に上書きされる。）
public struct ArtistGenConfig: Sendable, Equatable {
    /// LLM に渡すジャンル/スコープの自由記述（邦楽 / 洋楽 / クラシック等）。
    public var genrePrompt: String
    /// プールに保存したい組数（目標。20 でも 100 でも可）。
    public var targetCount: Int

    public init(
        genrePrompt: String = "日本の音楽アーティスト（邦楽）。バンド・ソロ・グループを問わず、誰もが知る有名どころ中心。",
        targetCount: Int = 100
    ) {
        self.genrePrompt = genrePrompt
        self.targetCount = targetCount
    }
}

/// `config/artist-gen.yaml` のローダ。欠落フィールドは struct の既定値で補う（ファイル無しは全既定）。
public enum ArtistGenConfigLoader {
    private struct File: Decodable {
        struct Generation: Decodable {
            let genre_prompt: String?
            let target_count: Int?
        }
        let generation: Generation?
    }

    public static func load(yaml: String) throws -> ArtistGenConfig {
        let defaults = ArtistGenConfig()
        if yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return defaults }
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        let gen = file.generation
        let prompt = (gen?.genre_prompt?.isEmpty == false) ? gen!.genre_prompt! : defaults.genrePrompt
        let count = gen?.target_count ?? defaults.targetCount
        return ArtistGenConfig(genrePrompt: prompt, targetCount: count >= 1 ? count : defaults.targetCount)
    }

    public static func load(path: String) throws -> ArtistGenConfig {
        guard let yaml = try? String(contentsOfFile: path, encoding: .utf8) else { return ArtistGenConfig() }
        return try load(yaml: yaml)
    }
}
