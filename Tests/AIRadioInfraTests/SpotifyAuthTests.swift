import Testing
import Foundation
import AIRadioCore
import AIRadioTestSupport
@testable import AIRadioInfra

struct SpotifyAuthTests {
    private func makeAuth(store: FakeTokenStore, http: FakeHTTPClient) -> SpotifyAuth {
        SpotifyAuth(
            clientId: "CID",
            redirectUri: "http://127.0.0.1:5543/callback",
            loopbackPort: 5543,
            scopes: ["user-read-playback-state"],
            store: store,
            http: http,
            clock: FakeClock()
        )
    }

    @Test func refreshesAccessTokenWhenRefreshTokenPresent() async throws {
        let store = FakeTokenStore(initial: "REFRESH")
        let http = FakeHTTPClient { _ in
            Data(#"{"access_token":"NEW","expires_in":3600,"refresh_token":"REFRESH2"}"#.utf8)
        }
        let auth = makeAuth(store: store, http: http)

        let token = try await auth.validAccessToken()

        #expect(token == "NEW")
        // ローテートされた refresh トークンが保存される
        #expect(store.load() == "REFRESH2")
        // token エンドポイントが叩かれている
        #expect(http.requests.contains { $0.url.absoluteString.contains("accounts.spotify.com/api/token") })
    }

    @Test func cachesAccessTokenAcrossCalls() async throws {
        let store = FakeTokenStore(initial: "REFRESH")
        let http = FakeHTTPClient { _ in
            Data(#"{"access_token":"NEW","expires_in":3600}"#.utf8)
        }
        let auth = makeAuth(store: store, http: http)

        _ = try await auth.validAccessToken()
        _ = try await auth.validAccessToken()

        let tokenCalls = http.requests.filter { $0.url.absoluteString.contains("api/token") }
        #expect(tokenCalls.count == 1)  // 2 回呼んでもトークン取得は 1 回（キャッシュ）
    }

    @Test func throwsAuthRequiredWhenNoRefreshToken() async {
        let store = FakeTokenStore(initial: nil)
        let http = FakeHTTPClient { _ in Data() }
        let auth = makeAuth(store: store, http: http)
        await #expect(throws: SpotifyError.authRequired) {
            _ = try await auth.validAccessToken()
        }
    }

    @Test func formEncodeEscapesValues() {
        let body = SpotifyAuth.formEncode(["grant_type": "refresh_token", "x": "a b/c"])
        let string = String(data: body, encoding: .utf8)!
        #expect(string.contains("grant_type=refresh_token"))
        #expect(string.contains("x=a%20b%2Fc"))
    }
}
