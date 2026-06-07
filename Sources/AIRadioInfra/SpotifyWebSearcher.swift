import Foundation
import AIRadioCore

/// Spotify Web API で曲検索・再生可否確認を行う `TrackSearcher` 実装。
/// アクセストークンは `SpotifyTokenProvider`（PKCE 認証）から取得する。
public struct SpotifyWebSearcher: TrackSearcher {
    private let auth: any SpotifyTokenProvider
    private let market: String
    private let http: any HTTPClient

    public init(auth: any SpotifyTokenProvider, market: String = "JP", http: any HTTPClient) {
        self.auth = auth
        self.market = market
        self.http = http
    }

    public func search(query: String, limit: Int) async throws -> [TrackInfo] {
        let token = try await auth.validAccessToken()
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
        let token = try await auth.validAccessToken()
        do {
            let id = SpotifyURI.trackId(from: uri)
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

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
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
