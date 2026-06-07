import Foundation
import AIRadioCore

/// AppleScript でローカル Spotify.app を制御する `SpotifyController` 実装。
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

    public func playerState() async throws -> PlayerState {
        let script = """
        tell application "Spotify"
        set st to player state as string
        set pos to player position
        set tid to ""
        try
        set tid to id of current track
        end try
        return st & "|" & tid & "|" & pos
        end tell
        """
        let raw = try await runner.run(script)
        return Self.parseState(raw)
    }

    /// `"<state>|<trackUri>|<position>"` 形式の文字列を `PlayerState` に変換する。
    static func parseState(_ raw: String) -> PlayerState {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let state: PlaybackState
        switch parts.first?.lowercased() {
        case "playing": state = .playing
        case "paused": state = .paused
        default: state = .stopped
        }
        let uri = (parts.count > 1 && !parts[1].isEmpty) ? parts[1] : nil
        let position = parts.count > 2 ? (Double(parts[2].replacingOccurrences(of: ",", with: ".")) ?? 0) : 0
        return PlayerState(state: state, trackUri: uri, positionSeconds: position)
    }
}
