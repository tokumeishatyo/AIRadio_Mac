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

    @Test func allPlayerStateScriptsAreSingleLine() async throws {
        let runner = FakeAppleScriptRunner(output: "playing")
        let controller = AppleScriptSpotifyController(runner: runner)
        _ = try await controller.playerState()
        // playerState は単一行コマンドを 3 回（state / position / track id）
        #expect(runner.scripts.count == 3)
        for script in runner.scripts {
            #expect(!script.contains("\n"))
            #expect(script.hasPrefix(#"tell application "Spotify" to "#))
        }
    }

    @Test func playerStateParsesPlaying() async throws {
        let runner = FakeAppleScriptRunner { script in
            if script.contains("player state") { return "playing" }
            if script.contains("player position") { return "12.5" }
            if script.contains("id of current track") { return "spotify:track:abc" }
            return ""
        }
        let controller = AppleScriptSpotifyController(runner: runner)
        let state = try await controller.playerState()
        #expect(state == PlayerState(state: .playing, trackUri: "spotify:track:abc", positionSeconds: 12.5))
    }

    @Test func currentTrackDurationConvertsMillisToSeconds() async throws {
        let runner = FakeAppleScriptRunner(output: "210000")  // 210000 ms
        let controller = AppleScriptSpotifyController(runner: runner)
        let duration = try await controller.currentTrackDurationSeconds()
        #expect(duration == 210.0)
        #expect(runner.scripts[0].contains("duration of current track"))
    }

    @Test func playerStateParsesStoppedWithEmptyTrack() async throws {
        let runner = FakeAppleScriptRunner { script in
            if script.contains("player state") { return "stopped" }
            if script.contains("player position") { return "0" }
            return ""  // id of current track → 空
        }
        let controller = AppleScriptSpotifyController(runner: runner)
        let state = try await controller.playerState()
        #expect(state == PlayerState(state: .stopped, trackUri: nil, positionSeconds: 0))
    }
}
