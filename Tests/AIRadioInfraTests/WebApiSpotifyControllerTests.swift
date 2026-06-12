import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

struct WebApiSpotifyControllerTests {
    private static let devicesJSON = Data(
        #"{"devices":[{"id":"DEV","is_active":true,"type":"Computer","name":"My Mac"}]}"#.utf8)
    private static let playbackJSON = Data(#"""
    {"is_playing":true,"progress_ms":12500,"item":{"uri":"spotify:track:abc","duration_ms":210000}}
    """#.utf8)

    private func makeController(_ responder: @escaping @Sendable (URL) throws -> Data) -> (WebApiSpotifyController, FakeHTTPClient) {
        let fake = FakeHTTPClient(responder: responder)
        let controller = WebApiSpotifyController(auth: FakeTokenProvider(token: "TOK"), http: fake)
        return (controller, fake)
    }

    @Test func playResolvesDeviceAndSendsUris() async throws {
        let (controller, fake) = makeController { url in
            url.absoluteString.contains("/devices") ? Self.devicesJSON : Data()
        }
        try await controller.play(uri: "spotify:track:abc")

        let playReq = fake.requests.first { $0.url.absoluteString.contains("/v1/me/player/play") }
        #expect(playReq?.method == "PUT")
        #expect(playReq?.url.query?.contains("device_id=DEV") == true)
        #expect(playReq?.headers["Authorization"] == "Bearer TOK")
        let bodyString = String(data: playReq?.body ?? Data(), encoding: .utf8) ?? ""
        #expect(bodyString.contains("spotify:track:abc"))
    }

    @Test func playWithoutDeviceThrowsNoDevice() async {
        let (controller, _) = makeController { url in
            url.absoluteString.contains("/devices") ? Data(#"{"devices":[]}"#.utf8) : Data()
        }
        await #expect(throws: SpotifyError.noDevice) {
            try await controller.play(uri: "spotify:track:abc")
        }
    }

    // スマホがアクティブでも、この Mac（Computer）を選ぶ。Connect 転送で別の場所で鳴らさない。
    @Test func playPrefersComputerOverActivePhone() async throws {
        let json = Data(#"""
        {"devices":[
          {"id":"PHONE","is_active":true,"type":"Smartphone","name":"iPhone"},
          {"id":"MAC","is_active":false,"type":"Computer","name":"My Mac"}
        ]}
        """#.utf8)
        let (controller, fake) = makeController { url in
            url.absoluteString.contains("/devices") ? json : Data()
        }
        try await controller.play(uri: "spotify:track:abc")
        let playReq = fake.requests.first { $0.url.absoluteString.contains("/v1/me/player/play") }
        #expect(playReq?.url.query?.contains("device_id=MAC") == true)
    }

    @Test func playWithoutComputerDeviceThrowsNoDevice() async {
        let json = Data(#"{"devices":[{"id":"PHONE","is_active":true,"type":"Smartphone","name":"iPhone"}]}"#.utf8)
        let (controller, _) = makeController { url in
            url.absoluteString.contains("/devices") ? json : Data()
        }
        await #expect(throws: SpotifyError.noDevice) {
            try await controller.play(uri: "spotify:track:abc")
        }
    }

    @Test func playHonorsPreferredDeviceName() async throws {
        let json = Data(#"""
        {"devices":[
          {"id":"MAC1","is_active":true,"type":"Computer","name":"Mac mini"},
          {"id":"MAC2","is_active":false,"type":"Computer","name":"Mac Studio"}
        ]}
        """#.utf8)
        let fake = FakeHTTPClient { url in
            url.absoluteString.contains("/devices") ? json : Data()
        }
        let controller = WebApiSpotifyController(
            auth: FakeTokenProvider(token: "TOK"), http: fake,
            retryDelaySeconds: 0, preferredDeviceName: "Mac Studio"
        )
        try await controller.play(uri: "spotify:track:abc")
        let playReq = fake.requests.first { $0.url.absoluteString.contains("/v1/me/player/play") }
        #expect(playReq?.url.query?.contains("device_id=MAC2") == true)
    }

    @Test func playWithMissingPreferredDeviceThrowsNoDevice() async {
        let fake = FakeHTTPClient { url in
            url.absoluteString.contains("/devices") ? Self.devicesJSON : Data()
        }
        let controller = WebApiSpotifyController(
            auth: FakeTokenProvider(token: "TOK"), http: fake,
            retryDelaySeconds: 0, preferredDeviceName: "ない子"
        )
        await #expect(throws: SpotifyError.noDevice) {
            try await controller.play(uri: "spotify:track:abc")
        }
    }

    @Test func setVolumeSendsPercent() async throws {
        let (controller, fake) = makeController { _ in Data() }
        try await controller.setVolume(80)
        let req = fake.requests.first { $0.url.absoluteString.contains("/v1/me/player/volume") }
        #expect(req?.method == "PUT")
        #expect(req?.url.query?.contains("volume_percent=80") == true)
    }

    @Test func seekConvertsSecondsToMillis() async throws {
        let (controller, fake) = makeController { _ in Data() }
        try await controller.seek(toSeconds: 30)
        let req = fake.requests.first { $0.url.absoluteString.contains("/v1/me/player/seek") }
        #expect(req?.url.query?.contains("position_ms=30000") == true)
    }

    @Test func pauseSendsPut() async throws {
        let (controller, fake) = makeController { _ in Data() }
        try await controller.pause()
        let req = fake.requests.first { $0.url.absoluteString.contains("/v1/me/player/pause") }
        #expect(req?.method == "PUT")
    }

    @Test func pauseSwallowsErrors() async throws {
        // 既に停止済みなどで 403 でも、後始末の pause は例外を投げない。
        let (controller, _) = makeController { _ in throw HTTPClientError.status(403) }
        try await controller.pause()  // throw しなければ成功
    }

    @Test func playerStateParsesPlayback() async throws {
        let (controller, _) = makeController { _ in Self.playbackJSON }
        let state = try await controller.playerState()
        // 曲長は URI・位置と同一スナップショットで返す（別問い合わせの stale 対策、S12 fix）。
        #expect(state == PlayerState(
            state: .playing, trackUri: "spotify:track:abc", positionSeconds: 12.5, durationSeconds: 210.0))
    }

    @Test func playerStateEmptyMeansStopped() async throws {
        let (controller, _) = makeController { _ in Data() }  // 204 No Content
        let state = try await controller.playerState()
        #expect(state == PlayerState(state: .stopped))
    }

    @Test func currentTrackDurationFromPlayback() async throws {
        let (controller, _) = makeController { _ in Self.playbackJSON }
        let duration = try await controller.currentTrackDurationSeconds()
        #expect(duration == 210.0)
    }

    /// 呼び出し回数を数えるスレッドセーフなカウンタ（stale デバイス 404 の再現用）。
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    @Test func playRetriesAfterStaleDevice404ViaTransfer() async throws {
        // アイドルで stale なデバイスは device_id 指定でも 404 を返す。
        // transfer playback で起こして再試行し、2 回目で成功する。
        let playAttempts = Counter()
        let fake = FakeHTTPClient { url in
            if url.absoluteString.contains("/devices") { return Self.devicesJSON }
            if url.absoluteString.contains("/v1/me/player/play") {
                if playAttempts.next() == 1 { throw HTTPClientError.status(404) }
                return Data()
            }
            return Data()  // transfer playback（PUT /v1/me/player）
        }
        let controller = WebApiSpotifyController(
            auth: FakeTokenProvider(token: "TOK"), http: fake, retryDelaySeconds: 0
        )
        try await controller.play(uri: "spotify:track:abc")

        let transfer = fake.requests.first {
            $0.url.absoluteString.hasSuffix("/v1/me/player") && $0.method == "PUT"
        }
        let body = String(data: transfer?.body ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("DEV"))
        #expect(body.contains("\"play\":false"))
        let plays = fake.requests.filter { $0.url.absoluteString.contains("/v1/me/player/play") }
        #expect(plays.count == 2)
    }

    @Test func playGivesUpAfterPersistent404() async {
        let fake = FakeHTTPClient { url in
            if url.absoluteString.contains("/devices") { return Self.devicesJSON }
            if url.absoluteString.contains("/v1/me/player/play") { throw HTTPClientError.status(404) }
            return Data()
        }
        let controller = WebApiSpotifyController(
            auth: FakeTokenProvider(token: "TOK"), http: fake, retryDelaySeconds: 0
        )
        await #expect(throws: SpotifyError.apiFailed("status(404)")) {
            try await controller.play(uri: "spotify:track:abc")
        }
        let plays = fake.requests.filter { $0.url.absoluteString.contains("/v1/me/player/play") }
        #expect(plays.count == 3)
    }
}
