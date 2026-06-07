import Foundation

/// Spotify トラック URI のユーティリティ。
public enum SpotifyURI {
    /// `spotify:track:<ID>` / 共有 URL / 裸 ID から track ID を取り出す。
    public static func trackId(from raw: String) -> String {
        if raw.hasPrefix("spotify:track:") {
            return String(raw.dropFirst("spotify:track:".count))
        }
        if let range = raw.range(of: "/track/") {
            let rest = raw[range.upperBound...]
            return String(rest.prefix { $0 != "?" && $0 != "/" })
        }
        return raw
    }

    /// 任意形式を `spotify:track:<ID>` に正規化する（AppleScript の play track 用）。
    public static func normalizeTrack(_ raw: String) -> String {
        "spotify:track:\(trackId(from: raw))"
    }
}
