import Foundation
import AIRadioCore

/// Spotify Web API でアーティストの代表曲（top-tracks）を取得する `ArtistCatalog` 実装（仕様 s15 §5）。
/// 1) `GET /v1/search?type=artist` で名前からアーティスト ID を解決（先頭ヒット）
/// 2) `GET /v1/artists/{id}/top-tracks?market=...` で上位曲（最大 10）を取得
/// market は `spotify.local.yaml` の値を使う（検索・top-tracks 共通）。
public struct SpotifyArtistCatalog: ArtistCatalog {
    private let auth: any SpotifyTokenProvider
    private let market: String
    private let http: any HTTPClient

    public init(auth: any SpotifyTokenProvider, market: String = "JP", http: any HTTPClient) {
        self.auth = auth
        self.market = market
        self.http = http
    }

    public func topTracks(artistName: String, limit: Int) async throws -> [TrackInfo] {
        let token = try await auth.validAccessToken()
        do {
            guard let artistId = try await resolveArtistId(name: artistName, token: token) else {
                return []   // アーティストが見つからない（非実在・配信なし等）
            }
            var components = URLComponents(string: "https://api.spotify.com/v1/artists/\(artistId)/top-tracks")!
            components.queryItems = [URLQueryItem(name: "market", value: market)]
            let data = try await http.get(url: components.url!, headers: ["Authorization": "Bearer \(token)"])
            let response = try makeDecoder().decode(TopTracksResponse.self, from: data)
            return response.tracks.prefix(limit).map {
                TrackInfo(
                    uri: $0.uri,
                    title: $0.name,
                    artist: $0.artists.first?.name ?? artistName,
                    isPlayable: $0.isPlayable ?? true
                )
            }
        } catch let error as SpotifyError {
            throw error
        } catch {
            throw SpotifyError.searchFailed(String(describing: error))
        }
    }

    private func resolveArtistId(name: String, token: String) async throws -> String? {
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: name),
            URLQueryItem(name: "type", value: "artist"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "market", value: market),
        ]
        let data = try await http.get(url: components.url!, headers: ["Authorization": "Bearer \(token)"])
        let response = try makeDecoder().decode(ArtistSearchResponse.self, from: data)
        return response.artists.items.first?.id
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private struct ArtistSearchResponse: Decodable {
        let artists: Artists
        struct Artists: Decodable { let items: [Item] }
        struct Item: Decodable { let id: String }
    }
    private struct TopTracksResponse: Decodable {
        let tracks: [Track]
        struct Track: Decodable {
            let uri: String
            let name: String
            let artists: [TrackArtist]
            let isPlayable: Bool?
        }
        struct TrackArtist: Decodable { let name: String }
    }
}
