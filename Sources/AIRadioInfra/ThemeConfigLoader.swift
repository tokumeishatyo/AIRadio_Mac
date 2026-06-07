import Foundation
import Yams
import AIRadioCore

/// 1 テーマセグメント（演出設定 + 発話文）。
public struct LoadedTheme: Sendable, Equatable {
    public let theme: ThemeConfig
    public let announcement: String
}

/// OP / ニュース / ED の 3 テーマ。
public struct ThemesConfig: Sendable, Equatable {
    public let opening: LoadedTheme
    public let news: LoadedTheme
    public let ending: LoadedTheme
}

/// `config/themes.yaml` のローダ。
public enum ThemeConfigLoader {
    private struct File: Decodable {
        struct Segment: Decodable {
            let tagline: String?
            let track_uri: String?
            let intro_seconds: Int?
            let volume: Int?
            let ducked_volume: Int?
            let outro_seconds: Int?
            let announcement: String?
        }
        let opening: Segment?
        let news: Segment?
        let ending: Segment?
    }

    public static func load(yaml: String) throws -> ThemesConfig {
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        return ThemesConfig(
            opening: try build(file.opening, name: "opening"),
            news: try build(file.news, name: "news"),
            ending: try build(file.ending, name: "ending")
        )
    }

    public static func load(path: String) throws -> ThemesConfig {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }

    private static func build(_ segment: File.Segment?, name: String) throws -> LoadedTheme {
        guard let segment else { throw ConfigError.missingField(name) }
        guard let rawUri = segment.track_uri, !rawUri.isEmpty else {
            throw ConfigError.missingField("\(name).track_uri")
        }
        let theme = ThemeConfig(
            tagline: segment.tagline,
            trackUri: SpotifyURI.normalizeTrack(rawUri),
            introSeconds: segment.intro_seconds ?? 5,
            volume: segment.volume ?? 85,
            duckedVolume: segment.ducked_volume ?? 35,
            outroSeconds: segment.outro_seconds ?? 15
        )
        return LoadedTheme(theme: theme, announcement: segment.announcement ?? "")
    }
}
