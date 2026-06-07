import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

struct WebApiSpotifyControllerTests {
    private static let devicesJSON = Data(#"{"devices":[{"id":"DEV","is_active":true}]}"#.utf8)
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
        #expect(state == PlayerState(state: .playing, trackUri: "spotify:track:abc", positionSeconds: 12.5))
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
}
