import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

struct SpotifyWebSearcherTests {
    private static let searchJSON = Data(#"""
    {"tracks":{"items":[
      {"uri":"spotify:track:abc","name":"アイドル","artists":[{"name":"YOASOBI"}],"is_playable":true}
    ]}}
    """#.utf8)

    @Test func searchParsesTracksAndUsesBearer() async throws {
        let fake = FakeHTTPClient { _ in Self.searchJSON }
        let searcher = SpotifyWebSearcher(auth: FakeTokenProvider(token: "TOK"), market: "JP", http: fake)

        let results = try await searcher.search(query: "YOASOBI アイドル", limit: 3)

        #expect(results == [TrackInfo(uri: "spotify:track:abc", title: "アイドル", artist: "YOASOBI", isPlayable: true)])
        let req = fake.requests.first { $0.url.absoluteString.contains("/v1/search") }
        #expect(req?.headers["Authorization"] == "Bearer TOK")
        #expect(req?.url.query?.contains("market=JP") == true)
    }

    @Test func isPlayableReadsTrackObject() async throws {
        let fake = FakeHTTPClient { url in
            url.absoluteString.contains("/v1/tracks/") ? Data(#"{"is_playable":false}"#.utf8) : Data()
        }
        let searcher = SpotifyWebSearcher(auth: FakeTokenProvider(), market: "JP", http: fake)
        let playable = try await searcher.isPlayable("spotify:track:abc")
        #expect(playable == false)
        #expect(fake.requests.contains { $0.url.absoluteString.contains("/v1/tracks/abc") })
    }

    @Test func httpErrorMapsToSearchFailed() async {
        let fake = FakeHTTPClient { _ in throw HTTPClientError.status(500) }
        let searcher = SpotifyWebSearcher(auth: FakeTokenProvider(), market: "JP", http: fake)
        await #expect(throws: SpotifyError.self) {
            _ = try await searcher.search(query: "x", limit: 1)
        }
    }
}
