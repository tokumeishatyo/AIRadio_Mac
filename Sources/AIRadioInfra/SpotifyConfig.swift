import Foundation
import Yams
import AIRadioCore

/// Spotify 設定（PKCE 認証 + Web API）。client_secret は不要（公開クライアント）。
public struct SpotifyConfig: Sendable, Equatable {
    public var clientId: String
    public var redirectUri: String
    public var market: String

    public init(clientId: String, redirectUri: String = "http://127.0.0.1:5543/callback", market: String = "JP") {
        self.clientId = clientId
        self.redirectUri = redirectUri
        self.market = market
    }

    /// リダイレクト URI から待受ポートを導出する。
    public var loopbackPort: UInt16 {
        if let port = URLComponents(string: redirectUri)?.port, port > 0, port <= 65535 {
            return UInt16(port)
        }
        return 5543
    }
}

/// `config/spotify.local.yaml` のローダ。
public enum SpotifyConfigLoader {
    private struct File: Decodable {
        struct Spotify: Decodable {
            let client_id: String?
            let redirect_uri: String?
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
        return SpotifyConfig(
            clientId: clientId,
            redirectUri: spotify.redirect_uri ?? "http://127.0.0.1:5543/callback",
            market: spotify.market ?? "JP"
        )
    }

    public static func load(path: String) throws -> SpotifyConfig {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }
}
