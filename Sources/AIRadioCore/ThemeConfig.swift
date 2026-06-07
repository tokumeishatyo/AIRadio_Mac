import Foundation

/// 統一テーマ/BGM 演出の設定（OP / ニュース / ED が共有）。
public struct ThemeConfig: Sendable, Equatable {
    /// BGM 前に喋る一言（ED は nil = いきなり BGM）。
    public var tagline: String?
    /// BGM の Spotify トラック URI（`spotify:track:<ID>` に正規化済み）。
    public var trackUri: String
    /// ダッキング前にフル音量で流す秒数。
    public var introSeconds: Int
    /// フル音量 %（0-100）。
    public var volume: Int
    /// 発話中の音量 %（0-100）。
    public var duckedVolume: Int
    /// 発話後、曲の「残り outroSeconds 秒」へシークし、曲の自然な終わりで停止する。
    /// （シーク位置 = 曲の長さ - outroSeconds。曲の長さが不明な場合は現在位置からそのまま）
    public var outroSeconds: Int

    public init(
        tagline: String?,
        trackUri: String,
        introSeconds: Int,
        volume: Int,
        duckedVolume: Int,
        outroSeconds: Int
    ) {
        self.tagline = tagline
        self.trackUri = trackUri
        self.introSeconds = introSeconds
        self.volume = volume
        self.duckedVolume = duckedVolume
        self.outroSeconds = outroSeconds
    }
}
