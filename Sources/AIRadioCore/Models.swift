import Foundation

/// LLM へのテキスト生成リクエスト。
public struct LLMRequest: Sendable, Equatable {
    public var prompt: String
    public var system: String?
    public var temperature: Double

    public init(prompt: String, system: String? = nil, temperature: Double = 0.7) {
        self.prompt = prompt
        self.system = system
        self.temperature = temperature
    }
}

/// 楽曲のメタ情報（Spotify 検索結果など）。
public struct TrackInfo: Sendable, Equatable {
    public var uri: String
    public var title: String
    public var artist: String
    public var isPlayable: Bool

    public init(uri: String, title: String, artist: String, isPlayable: Bool = true) {
        self.uri = uri
        self.title = title
        self.artist = artist
        self.isPlayable = isPlayable
    }
}

/// 再生状態。
public enum PlaybackState: String, Sendable, Equatable {
    case playing
    case paused
    case stopped
}

/// Spotify プレイヤーの現在状態。
public struct PlayerState: Sendable, Equatable {
    public var state: PlaybackState
    public var trackUri: String?
    public var positionSeconds: Double
    /// 現在の曲の長さ（秒）。**`trackUri`/`positionSeconds` と同一スナップショット**から取得した値。
    /// 別リクエストで取得した曲長は直前の曲のものを掴むことがある（stale、S12 fix）。取得不可は 0。
    public var durationSeconds: Double

    public init(
        state: PlaybackState,
        trackUri: String? = nil,
        positionSeconds: Double = 0,
        durationSeconds: Double = 0
    ) {
        self.state = state
        self.trackUri = trackUri
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
    }
}
