import Foundation
import AIRadioCore

/// Spotify Web API（Client Credentials）で曲検索・再生可否確認を行う `TrackSearcher` 実装。
/// アクセストークンを期限付きでキャッシュする（actor で安全に共有）。
public actor SpotifyWebSearcher: TrackSearcher {
    private let clientId: String
    private let clientSecret: String
    private let market: String
    private let http: any HTTPClient
    private let clock: any Clock

    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast

    public init(
        clientId: String,
        clientSecret: String,
        market: String = "JP",
        http: any HTTPClient,
        clock: any Clock
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.market = market
        self.http = http
        self.clock = clock
    }

    public func search(query: String, limit: Int) async throws -> [TrackInfo] {
        let token = try await accessToken()
        do {
            var components = URLComponents(string: "https://api.spotify.com/v1/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "track"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "market", value: market),
            ]
            let data = try await http.get(url: components.url!, headers: ["Authorization": "Bearer \(token)"])
            let response = try makeDecoder().decode(SearchResponse.self, from: data)
            return response.tracks.items.map {
                TrackInfo(
                    uri: $0.uri,
                    title: $0.name,
                    artist: $0.artists.first?.name ?? "",
                    isPlayable: $0.isPlayable ?? true
                )
            }
        } catch let error as SpotifyError {
            throw error
        } catch {
            throw SpotifyError.searchFailed(String(describing: error))
        }
    }

    public func isPlayable(_ uri: String) async throws -> Bool {
        let token = try await accessToken()
        do {
            let id = Self.trackId(from: uri)
            var components = URLComponents(string: "https://api.spotify.com/v1/tracks/\(id)")!
            components.queryItems = [URLQueryItem(name: "market", value: market)]
            let data = try await http.get(url: components.url!, headers: ["Authorization": "Bearer \(token)"])
            let track = try makeDecoder().decode(TrackObject.self, from: data)
            return track.isPlayable ?? true
        } catch let error as SpotifyError {
            throw error
        } catch {
            throw SpotifyError.searchFailed(String(describing: error))
        }
    }

    // MARK: - トークン

    private func accessToken() async throws -> String {
        if let token = cachedToken, clock.now < tokenExpiry {
            return token
        }
        do {
            let credential = Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()
            let url = URL(string: "https://accounts.spotify.com/api/token")!
            let body = Data("grant_type=client_credentials".utf8)
            let data = try await http.post(url: url, body: body, headers: [
                "Authorization": "Basic \(credential)",
                "Content-Type": "application/x-www-form-urlencoded",
            ])
            let response = try makeDecoder().decode(TokenResponse.self, from: data)
            cachedToken = response.accessToken
            tokenExpiry = clock.now.addingTimeInterval(Double(response.expiresIn) - 30)
            return response.accessToken
        } catch {
            throw SpotifyError.authFailed(String(describing: error))
        }
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// `spotify:track:ID` / 共有 URL / 裸 ID から track ID を取り出す。
    static func trackId(from uri: String) -> String {
        if uri.hasPrefix("spotify:track:") {
            return String(uri.dropFirst("spotify:track:".count))
        }
        if let range = uri.range(of: "/track/") {
            let rest = uri[range.upperBound...]
            return String(rest.prefix { $0 != "?" && $0 != "/" })
        }
        return uri
    }

    // MARK: - JSON モデル

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
    }
    private struct SearchResponse: Decodable {
        let tracks: Tracks
        struct Tracks: Decodable { let items: [Item] }
    }
    private struct Item: Decodable {
        let uri: String
        let name: String
        let artists: [Artist]
        let isPlayable: Bool?
    }
    private struct Artist: Decodable { let name: String }
    private struct TrackObject: Decodable { let isPlayable: Bool? }
}
