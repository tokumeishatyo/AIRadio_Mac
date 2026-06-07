import Foundation
import AIRadioCore

/// AppleScript でローカル Spotify.app を制御する `SpotifyController` 実装。
/// 各操作は実績のある単一行スクリプト（`tell application "Spotify" to ...`）で行う。
public struct AppleScriptSpotifyController: SpotifyController {
    private let runner: any AppleScriptRunner

    public init(runner: any AppleScriptRunner) {
        self.runner = runner
    }

    public func play(uri: String) async throws {
        _ = try await runner.run(#"tell application "Spotify" to play track "\#(uri)""#)
    }

    public func pause() async throws {
        _ = try await runner.run(#"tell application "Spotify" to pause"#)
    }

    public func setVolume(_ percent: Int) async throws {
        let clamped = max(0, min(100, percent))
        _ = try await runner.run(#"tell application "Spotify" to set sound volume to \#(clamped)"#)
    }

    public func seek(toSeconds seconds: Int) async throws {
        _ = try await runner.run(#"tell application "Spotify" to set player position to \#(seconds)"#)
    }

    public func currentTrackDurationSeconds() async throws -> Double {
        // Spotify の AppleScript は duration をミリ秒で返す。
        let raw = try await runner.run(#"tell application "Spotify" to return duration of current track"#)
        let ms = Double(raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
        return ms / 1000.0
    }

    public func playerState() async throws -> PlayerState {
        // 複数行スクリプトは osascript の解釈で構文エラーになりやすいため、
        // 単一行コマンドを 3 回に分けて取得する（再生・音量と同じ実績のある形）。
        let stateRaw = try await runner.run(#"tell application "Spotify" to return player state as string"#)
        let positionRaw = try await runner.run(#"tell application "Spotify" to return player position"#)
        let trackRaw = (try? await runner.run(#"tell application "Spotify" to return id of current track"#)) ?? ""

        let state: PlaybackState
        switch stateRaw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "playing": state = .playing
        case "paused": state = .paused
        default: state = .stopped
        }
        let trimmedTrack = trackRaw.trimmingCharacters(in: .whitespaces)
        let uri = trimmedTrack.isEmpty ? nil : trimmedTrack
        let position = Double(positionRaw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
        return PlayerState(state: state, trackUri: uri, positionSeconds: position)
    }
}
