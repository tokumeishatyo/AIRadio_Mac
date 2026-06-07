import Foundation
import AIRadioCore

/// Spotify Web API でローカル/任意デバイスの再生を制御する `SpotifyController` 実装。
/// `play` は再生キューを指定 URI だけに置き換えてアトミックに再生する（前曲のブリップが起きない）。
public struct WebApiSpotifyController: SpotifyController {
    private let auth: any SpotifyTokenProvider
    private let http: any HTTPClient

    public init(auth: any SpotifyTokenProvider, http: any HTTPClient) {
        self.auth = auth
        self.http = http
    }

    public func play(uri: String) async throws {
        let token = try await auth.validAccessToken()
        let deviceId = try await activeDeviceId(token: token)
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/play")!
        components.queryItems = [URLQueryItem(name: "device_id", value: deviceId)]
        let body = try JSONSerialization.data(withJSONObject: ["uris": [uri]])
        try await send(method: .put, url: components.url!, body: body, token: token, json: true)
    }

    public func pause() async throws {
        // 後始末（完全静寂）。既に停止済み（曲の自然終了直後など）は Spotify が 403 を返すが、
        // 結果は同じ「無音」なので握り潰す（Windows PauseAsync 同方針、CLAUDE.md §3-1 ベストエフォート）。
        do {
            let token = try await auth.validAccessToken()
            try await send(method: .put, url: URL(string: "https://api.spotify.com/v1/me/player/pause")!, body: nil, token: token)
        } catch {
            // 既に停止 / デバイスなし / 認証切れ等。後始末なので伝播させない。
        }
    }

    public func setVolume(_ percent: Int) async throws {
        let token = try await auth.validAccessToken()
        let clamped = max(0, min(100, percent))
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/volume")!
        components.queryItems = [URLQueryItem(name: "volume_percent", value: String(clamped))]
        try await send(method: .put, url: components.url!, body: nil, token: token)
    }

    public func seek(toSeconds seconds: Int) async throws {
        let token = try await auth.validAccessToken()
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/seek")!
        components.queryItems = [URLQueryItem(name: "position_ms", value: String(max(0, seconds) * 1000))]
        try await send(method: .put, url: components.url!, body: nil, token: token)
    }

    public func playerState() async throws -> PlayerState {
        let playback = try await currentPlayback()
        guard let playback else { return PlayerState(state: .stopped) }
        let state: PlaybackState = playback.isPlaying ? .playing : .paused
        return PlayerState(
            state: state,
            trackUri: playback.item?.uri,
            positionSeconds: Double(playback.progressMs ?? 0) / 1000.0
        )
    }

    public func currentTrackDurationSeconds() async throws -> Double {
        let playback = try await currentPlayback()
        return Double(playback?.item?.durationMs ?? 0) / 1000.0
    }

    // MARK: - 内部

    private enum Method: String { case put = "PUT" }

    private func send(method: Method, url: URL, body: Data?, token: String, json: Bool = false) async throws {
        var headers = ["Authorization": "Bearer \(token)"]
        if json { headers["Content-Type"] = "application/json" }
        do {
            _ = try await http.put(url: url, body: body, headers: headers)
        } catch {
            throw SpotifyError.apiFailed(String(describing: error))
        }
    }

    private func currentPlayback() async throws -> PlaybackResponse? {
        let token = try await auth.validAccessToken()
        do {
            let data = try await http.get(
                url: URL(string: "https://api.spotify.com/v1/me/player")!,
                headers: ["Authorization": "Bearer \(token)"]
            )
            if data.isEmpty { return nil }  // 204 No Content = アクティブデバイスなし
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(PlaybackResponse.self, from: data)
        } catch {
            throw SpotifyError.apiFailed(String(describing: error))
        }
    }

    private func activeDeviceId(token: String) async throws -> String {
        do {
            let data = try await http.get(
                url: URL(string: "https://api.spotify.com/v1/me/player/devices")!,
                headers: ["Authorization": "Bearer \(token)"]
            )
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let response = try decoder.decode(DevicesResponse.self, from: data)
            if let active = response.devices.first(where: { $0.isActive }) ?? response.devices.first {
                return active.id
            }
            throw SpotifyError.noDevice
        } catch let error as SpotifyError {
            throw error
        } catch {
            throw SpotifyError.apiFailed(String(describing: error))
        }
    }

    // MARK: - JSON モデル

    private struct DevicesResponse: Decodable {
        let devices: [Device]
        struct Device: Decodable {
            let id: String
            let isActive: Bool
        }
    }
    private struct PlaybackResponse: Decodable {
        let isPlaying: Bool
        let progressMs: Int?
        let item: Item?
        struct Item: Decodable {
            let uri: String
            let durationMs: Int
        }
    }
}
