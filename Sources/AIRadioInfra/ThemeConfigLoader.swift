import Foundation
import Yams
import AIRadioCore

/// 1 テーマセグメント（演出設定 + 発話文）。news 用（単一の読み手）。
public struct LoadedTheme: Sendable, Equatable {
    public let theme: ThemeConfig
    public let announcement: String
}

/// OP / ニュース / ED の 3 テーマ + 時間帯挨拶。
/// OP / ED は DJ 別の固定口上（`ThemedSegment`）、news は単一（`LoadedTheme`、龍星固定。仕様 s13.5 §4）。
public struct ThemesConfig: Sendable, Equatable {
    public let opening: ThemedSegment
    public let news: LoadedTheme
    public let ending: ThemedSegment
    public let greetings: Greetings
}

/// `config/themes.yaml` のローダ。
public enum ThemeConfigLoader {
    private struct File: Decodable {
        struct Spiel: Decodable {
            let tagline: String?
            let announcement: String?
        }
        struct Segment: Decodable {
            let tagline: String?       // news 用（単一）。OP/ED は by_dj 側に持つ。
            let track_uri: String?
            let intro_seconds: Int?
            let volume: Int?
            let ducked_volume: Int?
            let outro_seconds: Int?
            let announcement: String?  // news 用（単一）。
            let by_dj: [String: Spiel]?  // OP/ED の DJ 別固定口上。
        }
        struct GreetingsSection: Decodable {
            let morning: String?
            let afternoon: String?
            let evening: String?
        }
        let opening: Segment?
        let news: Segment?
        let ending: Segment?
        let greetings: GreetingsSection?
    }

    public static func load(yaml: String) throws -> ThemesConfig {
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        let defaults = Greetings()
        return ThemesConfig(
            opening: try buildThemed(file.opening, name: "opening"),
            news: try buildSingle(file.news, name: "news"),
            ending: try buildThemed(file.ending, name: "ending"),
            greetings: Greetings(
                morning: file.greetings?.morning ?? defaults.morning,
                afternoon: file.greetings?.afternoon ?? defaults.afternoon,
                evening: file.greetings?.evening ?? defaults.evening
            )
        )
    }

    public static func load(path: String) throws -> ThemesConfig {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }

    /// 共有 BGM 演出（tagline は per-DJ のため nil。発話直前にメインの tagline を載せる）。
    private static func staging(_ segment: File.Segment, name: String) throws -> ThemeConfig {
        guard let rawUri = segment.track_uri, !rawUri.isEmpty else {
            throw ConfigError.missingField("\(name).track_uri")
        }
        return ThemeConfig(
            tagline: nil,
            trackUri: SpotifyURI.normalizeTrack(rawUri),
            introSeconds: segment.intro_seconds ?? 5,
            volume: segment.volume ?? 85,
            duckedVolume: segment.ducked_volume ?? 35,
            outroSeconds: segment.outro_seconds ?? 15
        )
    }

    /// OP / ED: 共有演出 + DJ 別固定口上。
    private static func buildThemed(_ segment: File.Segment?, name: String) throws -> ThemedSegment {
        guard let segment else { throw ConfigError.missingField(name) }
        let staging = try staging(segment, name: name)
        guard let byDjFile = segment.by_dj, !byDjFile.isEmpty else {
            throw ConfigError.missingField("\(name).by_dj")
        }
        var byDj: [String: DjSpiel] = [:]
        for (id, spiel) in byDjFile {
            guard let announcement = spiel.announcement, !announcement.isEmpty else {
                throw ConfigError.missingField("\(name).by_dj.\(id).announcement")
            }
            byDj[id] = DjSpiel(tagline: spiel.tagline, announcement: announcement)
        }
        return ThemedSegment(staging: staging, byDj: byDj)
    }

    /// news: 単一の読み手（tagline をそのまま保持）。
    private static func buildSingle(_ segment: File.Segment?, name: String) throws -> LoadedTheme {
        guard let segment else { throw ConfigError.missingField(name) }
        var theme = try staging(segment, name: name)
        theme.tagline = segment.tagline   // news はタグラインを使う
        return LoadedTheme(theme: theme, announcement: segment.announcement ?? "")
    }
}
