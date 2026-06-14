import Foundation
import Yams
import AIRadioCore

/// `config/artists.yaml` のローダ（アーティスト特集のプール。仕様 s15 §9）。
/// **出荷時は空**（メニューの生成ボタンで作成）。空・未生成は正常（空配列を返す）、
/// ファイルが存在して壊れている（パース不能 / 必須欠落 / 重複）場合のみ throw（fail-fast）。
public enum ArtistsConfigLoader {
    private struct File: Decodable {
        struct Artist: Decodable {
            let id: String?
            let name: String?
            let reading: String?   // 任意（仕様 s19b。カタカナ読み）
        }
        let artists: [Artist]?
    }

    public static func load(yaml: String) throws -> [ArtistProfile] {
        // 空文字・コメントのみ（出荷時の空ファイル）は正常＝空プール。
        let meaningful = yaml.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        if !meaningful { return [] }
        let file: File
        do {
            file = try YAMLDecoder().decode(File.self, from: yaml)
        } catch {
            throw ConfigError.missingField("artists.yaml を解釈できません: \(error)")
        }
        guard let artists = file.artists, !artists.isEmpty else {
            return []   // `artists:` が無い／空も正常（特集はスキップされる）
        }
        var seenId = Set<String>()
        var seenName = Set<String>()
        return try artists.map { artist in
            guard let id = artist.id, !id.isEmpty else { throw ConfigError.missingField("artists[].id") }
            guard let name = artist.name, !name.isEmpty else { throw ConfigError.missingField("artists[].name (\(id))") }
            guard seenId.insert(id).inserted else { throw ConfigError.missingField("artists[].id が重複: \(id)") }
            let canonical = canonicalName(name)
            guard canonical.isEmpty || seenName.insert(canonical).inserted else {
                throw ConfigError.missingField("artists[].name が重複: \(name)")
            }
            return ArtistProfile(id: id, name: name, reading: artist.reading)
        }
    }

    public static func load(path: String) throws -> [ArtistProfile] {
        // ファイルが無いのは正常（出荷時は空＝未生成）。
        guard let yaml = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try load(yaml: yaml)
    }

    /// 重複判定用の正規化名（前後空白除去・小文字化・全角/半角スペース除去）。
    static func canonicalName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}
