import Testing
import Foundation
import AIRadioCore
import AIRadioTestSupport
@testable import AIRadioInfra

struct SpotifyWebSearcherTests {
    private static let tokenJSON = Data(#"{"access_token":"TOK","expires_in":3600}"#.utf8)
    private static let searchJSON = Data(#"""
    {"tracks":{"items":[
      {"uri":"spotify:track:abc","name":"アイドル","artists":[{"name":"YOASOBI"}],"is_playable":true}
    ]}}
    """#.utf8)

    private func makeFake(searchBody: Data = searchJSON, trackBody: Data = Data(#"{"is_playable":false}"#.utf8)) -> FakeHTTPClient {
        FakeHTTPClient { url in
            let s = url.absoluteString
            if s.contains("accounts.spotify.com/api/token") { return Self.tokenJSON }
            if s.contains("/v1/search") { return searchBody }
            if s.contains("/v1/tracks/") { return trackBody }
            return Data()
        }
    }

    @Test func searchParsesTracksAndUsesBearer() async throws {
        let fake = makeFake()
        let searcher = SpotifyWebSearcher(
            clientId: "id", clientSecret: "secret", market: "JP", http: fake, clock: FakeClock()
        )

        let results = try await searcher.search(query: "YOASOBI アイドル", limit: 3)

        #expect(results == [TrackInfo(uri: "spotify:track:abc", title: "アイドル", artist: "YOASOBI", isPlayable: true)])

        // トークン取得 → 検索 の順
        let searchReq = fake.requests.first { $0.url.absoluteString.contains("/v1/search") }
        #expect(searchReq?.headers["Authorization"] == "Bearer TOK")
        #expect(searchReq?.url.query?.contains("market=JP") == true)

        let tokenReq = fake.requests.first { $0.url.absoluteString.contains("api/token") }
        #expect(tokenReq?.headers["Authorization"]?.hasPrefix("Basic ") == true)
    }

    @Test func tokenIsCachedAcrossCalls() async throws {
        let fake = makeFake()
        let searcher = SpotifyWebSearcher(
            clientId: "id", clientSecret: "secret", http: fake, clock: FakeClock()
        )
        _ = try await searcher.search(query: "a", limit: 1)
        _ = try await searcher.search(query: "b", limit: 1)

        let tokenCalls = fake.requests.filter { $0.url.absoluteString.contains("api/token") }
        #expect(tokenCalls.count == 1)  // 2 回検索してもトークン取得は 1 回
    }

    @Test func isPlayableReadsTrackObject() async throws {
        let fake = makeFake(trackBody: Data(#"{"is_playable":false}"#.utf8))
        let searcher = SpotifyWebSearcher(
            clientId: "id", clientSecret: "secret", http: fake, clock: FakeClock()
        )
        let playable = try await searcher.isPlayable("spotify:track:abc")
        #expect(playable == false)

        let trackReq = fake.requests.first { $0.url.absoluteString.contains("/v1/tracks/abc") }
        #expect(trackReq != nil)
    }

    @Test func tokenFailureMapsToAuthFailed() async {
        let fake = FakeHTTPClient { _ in throw HTTPClientError.status(400) }
        let searcher = SpotifyWebSearcher(
            clientId: "id", clientSecret: "bad", http: fake, clock: FakeClock()
        )
        await #expect(throws: SpotifyError.self) {
            _ = try await searcher.search(query: "x", limit: 1)
        }
    }

    @Test func trackIdExtraction() {
        #expect(SpotifyWebSearcher.trackId(from: "spotify:track:XYZ") == "XYZ")
        #expect(SpotifyWebSearcher.trackId(from: "https://open.spotify.com/track/XYZ?si=abc") == "XYZ")
        #expect(SpotifyWebSearcher.trackId(from: "XYZ") == "XYZ")
    }
}
