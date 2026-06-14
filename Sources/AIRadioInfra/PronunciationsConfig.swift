import Foundation
import Yams
import AIRadioCore

/// `config/pronunciations.yaml` のローダ（読み辞書。仕様 s19a §3）。
/// 空・未生成・ファイル無しは正常（空配列を返す＝同期なし）、
/// ファイルが存在して壊れている（パース不能 / 必須欠落）場合のみ throw（fail-fast）。
/// 規約は `ArtistsConfigLoader` に倣う。
public enum PronunciationsConfigLoader {
    private struct File: Decodable {
        struct Entry: Decodable {
            let surface: String?
            let pronunciation: String?
            let accent_type: Int?
            let word_type: String?
            let priority: Int?
        }
        let pronunciations: [Entry]?
    }

    public static func load(yaml: String) throws -> [PronunciationEntry] {
        // 空文字・コメントのみ（出荷時の空ファイル）は正常＝空辞書。
        let meaningful = yaml.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        if !meaningful { return [] }
        let file: File
        do {
            file = try YAMLDecoder().decode(File.self, from: yaml)
        } catch {
            throw ConfigError.missingField("pronunciations.yaml を解釈できません: \(error)")
        }
        guard let entries = file.pronunciations, !entries.isEmpty else {
            return []   // `pronunciations:` が無い／空も正常（同期なし）。
        }
        return try entries.map { entry in
            guard let surface = entry.surface, !surface.isEmpty else {
                throw ConfigError.missingField("pronunciations[].surface")
            }
            guard let pronunciation = entry.pronunciation, !pronunciation.isEmpty else {
                throw ConfigError.missingField("pronunciations[].pronunciation (\(surface))")
            }
            return PronunciationEntry(
                surface: surface,
                pronunciation: pronunciation,
                accentType: entry.accent_type ?? 0,
                wordType: entry.word_type,
                priority: entry.priority
            )
        }
    }

    public static func load(path: String) throws -> [PronunciationEntry] {
        // ファイルが無いのは正常（出荷時に同梱しない運用も許容）。
        guard let yaml = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try load(yaml: yaml)
    }
}
