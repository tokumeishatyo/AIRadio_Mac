import Foundation

/// テキスト生成（Gemini / Gemma 等）。
public protocol LLMBackend: Sendable {
    func generate(_ request: LLMRequest) async throws -> String
}

/// 音声合成（VOICEVOX 等）。戻り値は WAV バイト列。
public protocol TTSBackend: Sendable {
    func synthesize(text: String, speakerId: Int) async throws -> Data
}

/// 合成済み音声（WAV）の再生。再生完了まで待機する。
public protocol AudioPlayer: Sendable {
    func play(_ wav: Data) async throws
}

/// 楽曲検索・再生可否確認（Spotify Web API, Client Credentials）。
public protocol TrackSearcher: Sendable {
    func search(query: String, limit: Int) async throws -> [TrackInfo]
    func isPlayable(_ uri: String) async throws -> Bool
}

/// Spotify 再生制御（AppleScript）。
public protocol SpotifyController: Sendable {
    func play(uri: String) async throws
    func pause() async throws
    func setVolume(_ percent: Int) async throws
    func seek(toSeconds seconds: Int) async throws
    func playerState() async throws -> PlayerState
    /// 現在の曲の長さ（秒）。取得できない場合は 0。
    func currentTrackDurationSeconds() async throws -> Double
}

/// 外部リサーチ素材の取得（News RSS / 気象庁 等）。
public protocol ResearchSource: Sendable {
    func fetch() async throws -> String
}

/// 時刻と待機の抽象（テストで差し替え可能にする）。
public protocol Clock: Sendable {
    var now: Date { get }
    func sleep(seconds: Double) async throws
}
