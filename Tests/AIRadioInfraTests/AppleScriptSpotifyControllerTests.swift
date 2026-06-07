import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

struct AppleScriptSpotifyControllerTests {
    @Test func playGeneratesPlayTrackScript() async throws {
        let runner = FakeAppleScriptRunner()
        let controller = AppleScriptSpotifyController(runner: runner)
        try await controller.play(uri: "spotify:track:abc")
        #expect(runner.scripts.count == 1)
        #expect(runner.scripts[0].contains(#"play track "spotify:track:abc""#))
    }

    @Test func setVolumeClampsAndGeneratesScript() async throws {
        let runner = FakeAppleScriptRunner()
        let controller = AppleScriptSpotifyController(runner: runner)
        try await controller.setVolume(150)
        #expect(runner.scripts[0].contains("set sound volume to 100"))
        try await controller.setVolume(-10)
        #expect(runner.scripts[1].contains("set sound volume to 0"))
    }

    @Test func seekGeneratesPlayerPositionScript() async throws {
        let runner = FakeAppleScriptRunner()
        let controller = AppleScriptSpotifyController(runner: runner)
        try await controller.seek(toSeconds: 30)
        #expect(runner.scripts[0].contains("set player position to 30"))
    }

    @Test func pauseGeneratesPauseScript() async throws {
        let runner = FakeAppleScriptRunner()
        let controller = AppleScriptSpotifyController(runner: runner)
        try await controller.pause()
        #expect(runner.scripts[0].contains("pause"))
    }

    @Test func playerStateParsesPlaying() async throws {
        let runner = FakeAppleScriptRunner(output: "playing|spotify:track:abc|12.5")
        let controller = AppleScriptSpotifyController(runner: runner)
        let state = try await controller.playerState()
        #expect(state == PlayerState(state: .playing, trackUri: "spotify:track:abc", positionSeconds: 12.5))
    }

    @Test func playerStateParsesStoppedWithEmptyTrack() async throws {
        let runner = FakeAppleScriptRunner(output: "stopped||0")
        let controller = AppleScriptSpotifyController(runner: runner)
        let state = try await controller.playerState()
        #expect(state == PlayerState(state: .stopped, trackUri: nil, positionSeconds: 0))
    }
}
