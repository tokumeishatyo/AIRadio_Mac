import Foundation
import Yams
import AIRadioCore

/// `config/corners.yaml` のローダ（コーナーテンプレートの一覧）。
public enum CornersConfigLoader {
    private struct File: Decodable {
        struct Corner: Decodable {
            let id: String?
            let title: String?
            let theme: String?
            let themes: [String]?
            let format: String?
            let dj_ids: [String]?
            let target_minutes: Int?
            let chars_per_minute: Int?
            let song_prompt_hint: String?
            let fallback_track_uri: String?
            let volume: Int?
            let play_seconds: Int?
            let lead_in: String?
        }
        let corners: [Corner]?
    }

    public static func load(yaml: String) throws -> [CornerTemplate] {
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        guard let corners = file.corners, !corners.isEmpty else {
            throw ConfigError.missingField("corners")
        }
        return try corners.map { corner in
            guard let id = corner.id, !id.isEmpty else { throw ConfigError.missingField("corners[].id") }
            guard let title = corner.title, !title.isEmpty else { throw ConfigError.missingField("corners[].title (\(id))") }
            guard let theme = corner.theme, !theme.isEmpty else { throw ConfigError.missingField("corners[].theme (\(id))") }
            guard let djIds = corner.dj_ids, !djIds.isEmpty else { throw ConfigError.missingField("corners[].dj_ids (\(id))") }
            guard let fallback = corner.fallback_track_uri, !fallback.isEmpty else {
                throw ConfigError.missingField("corners[].fallback_track_uri (\(id))")
            }
            let format: CornerFormat
            if let raw = corner.format {
                guard let parsed = CornerFormat(rawValue: raw) else {
                    throw ConfigError.missingField("corners[].format (\(id)) が不正な値: \(raw)")
                }
                format = parsed
            } else {
                format = .freeTalk
            }
            return CornerTemplate(
                id: id,
                title: title,
                theme: theme,
                themePool: corner.themes ?? [],
                format: format,
                djIds: djIds,
                targetMinutes: corner.target_minutes ?? 5,
                charsPerMinute: corner.chars_per_minute ?? 320,
                songPromptHint: corner.song_prompt_hint ?? "",
                fallbackTrackUri: SpotifyURI.normalizeTrack(fallback),
                volume: corner.volume ?? 85,
                playSeconds: corner.play_seconds ?? 0,
                leadIn: corner.lead_in ?? ""
            )
        }
    }

    public static func load(path: String) throws -> [CornerTemplate] {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }
}
