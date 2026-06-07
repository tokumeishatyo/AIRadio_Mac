import Foundation
import Yams
import AIRadioCore

/// Spotify 認証設定（Web API 検索用）。
public struct SpotifyConfig: Sendable, Equatable {
    public var clientId: String
    public var clientSecret: String
    public var market: String

    public init(clientId: String, clientSecret: String, market: String = "JP") {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.market = market
    }
}

/// `config/spotify.local.yaml` のローダ。
public enum SpotifyConfigLoader {
    private struct File: Decodable {
        struct Spotify: Decodable {
            let client_id: String?
            let client_secret: String?
            let market: String?
        }
        let spotify: Spotify?
    }

    public static func load(yaml: String) throws -> SpotifyConfig {
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        guard let spotify = file.spotify,
              let clientId = spotify.client_id,
              !clientId.isEmpty
        else {
            throw ConfigError.missingField("spotify.client_id")
        }
        guard let clientSecret = spotify.client_secret, !clientSecret.isEmpty else {
            throw ConfigError.missingField("spotify.client_secret")
        }
        return SpotifyConfig(
            clientId: clientId,
            clientSecret: clientSecret,
            market: spotify.market ?? "JP"
        )
    }

    public static func load(path: String) throws -> SpotifyConfig {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }
}
