import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

struct SpotifyArtistCatalogTests {
    @Test("artist 解決 → top-tracks を TrackInfo に変換")
    func resolvesAndFetchesTopTracks() async throws {
        let fake = FakeHTTPClient { url in
            if url.absoluteString.contains("/v1/search") {
                return Data(#"{"artists":{"items":[{"id":"ART1"}]}}"#.utf8)
            }
            if url.absoluteString.contains("/top-tracks") {
                return Data(#"""
                {"tracks":[
                  {"uri":"spotify:track:1","name":"曲1","artists":[{"name":"米津玄師"}],"is_playable":true},
                  {"uri":"spotify:track:2","name":"曲2","artists":[{"name":"米津玄師"}]}
                ]}
                """#.utf8)
            }
            return Data()
        }
        let catalog = SpotifyArtistCatalog(auth: FakeTokenProvider(token: "TOK"), market: "JP", http: fake)
        let tracks = try await catalog.topTracks(artistName: "米津玄師", limit: 10)

        #expect(tracks.count == 2)
        #expect(tracks.first == TrackInfo(uri: "spotify:track:1", title: "曲1", artist: "米津玄師", isPlayable: true))
        // search は type=artist & market=JP、top-tracks は artist id を含む。
        #expect(fake.requests.contains { $0.url.query?.contains("type=artist") == true })
        #expect(fake.requests.contains { $0.url.absoluteString.contains("/v1/artists/ART1/top-tracks") })
    }

    @Test("artist が見つからなければ空配列")
    func emptyWhenArtistNotFound() async throws {
        let fake = FakeHTTPClient { url in
            url.absoluteString.contains("/v1/search") ? Data(#"{"artists":{"items":[]}}"#.utf8) : Data()
        }
        let catalog = SpotifyArtistCatalog(auth: FakeTokenProvider(), market: "JP", http: fake)
        #expect(try await catalog.topTracks(artistName: "無名アーティスト", limit: 10).isEmpty)
    }

    @Test("limit で件数を絞る")
    func respectsLimit() async throws {
        let fake = FakeHTTPClient { url in
            if url.absoluteString.contains("/v1/search") { return Data(#"{"artists":{"items":[{"id":"A"}]}}"#.utf8) }
            return Data(#"""
            {"tracks":[
              {"uri":"u1","name":"1","artists":[{"name":"X"}]},
              {"uri":"u2","name":"2","artists":[{"name":"X"}]},
              {"uri":"u3","name":"3","artists":[{"name":"X"}]}
            ]}
            """#.utf8)
        }
        let catalog = SpotifyArtistCatalog(auth: FakeTokenProvider(), market: "JP", http: fake)
        #expect(try await catalog.topTracks(artistName: "X", limit: 2).count == 2)
    }
}
