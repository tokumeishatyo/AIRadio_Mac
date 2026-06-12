import Foundation
import AIRadioCore

/// Spotify Web API でローカル/任意デバイスの再生を制御する `SpotifyController` 実装。
/// `play` は再生キューを指定 URI だけに置き換えてアトミックに再生する（前曲のブリップが起きない）。
public struct WebApiSpotifyController: SpotifyController {
    private let auth: any SpotifyTokenProvider
    private let http: any HTTPClient
    private let retryDelaySeconds: Double
    private let preferredDeviceName: String?

    public init(
        auth: any SpotifyTokenProvider,
        http: any HTTPClient,
        retryDelaySeconds: Double = 1.0,
        preferredDeviceName: String? = nil
    ) {
        self.auth = auth
        self.http = http
        self.retryDelaySeconds = retryDelaySeconds
        self.preferredDeviceName = preferredDeviceName
    }

    public func play(uri: String) async throws {
        let token = try await auth.validAccessToken()
        let body = try JSONSerialization.data(withJSONObject: ["uris": [uri]])
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let deviceId = try await activeDeviceId(token: token)
            var components = URLComponents(string: "https://api.spotify.com/v1/me/player/play")!
            components.queryItems = [URLQueryItem(name: "device_id", value: deviceId)]
            do {
                _ = try await http.put(url: components.url!, body: body, headers: [
                    "Authorization": "Bearer \(token)",
                    "Content-Type": "application/json",
                ])
                return
            } catch HTTPClientError.status(404) where attempt < maxAttempts {
                // デバイスを長時間操作していないと登録が stale になり、device_id 指定でも 404 が返る。
                // transfer playback でデバイスを起こしてから再試行する。
                try? await transferPlayback(to: deviceId, token: token)
                try await Task.sleep(nanoseconds: UInt64(retryDelaySeconds * 1_000_000_000))
            } catch let error as SpotifyError {
                throw error
            } catch {
                throw SpotifyError.apiFailed(String(describing: error))
            }
        }
        throw SpotifyError.noDevice
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
            positionSeconds: Double(playback.progressMs ?? 0) / 1000.0,
            // 曲長は同一スナップショットから返す（別リクエストで取り直すと
            // 直前の曲の値を掴むことがある = stale、S12 fix）。
            durationSeconds: Double(playback.item?.durationMs ?? 0) / 1000.0
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

    /// 再生先デバイスへの transfer playback（スリープ状態のデバイスを起こす。play: false = 即再生しない）。
    private func transferPlayback(to deviceId: String, token: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["device_ids": [deviceId], "play": false])
        _ = try await http.put(
            url: URL(string: "https://api.spotify.com/v1/me/player")!,
            body: body,
            headers: [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
            ]
        )
    }

    /// 再生先デバイスの選択。**この Mac の Spotify 以外に勝手に飛ばさない**:
    /// - `preferredDeviceName` 指定時: 名前一致のみ（なければ noDevice）。
    /// - 未指定時: type=Computer のデバイス（アクティブ優先）。Computer がなければ noDevice。
    ///   （`devices.first` への安易なフォールバックは、スマホ等へ Spotify Connect 転送して
    ///    別の場所で鳴らす事故になるため行わない。）
    private func activeDeviceId(token: String) async throws -> String {
        do {
            let data = try await http.get(
                url: URL(string: "https://api.spotify.com/v1/me/player/devices")!,
                headers: ["Authorization": "Bearer \(token)"]
            )
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let devices = try decoder.decode(DevicesResponse.self, from: data).devices

            if let name = preferredDeviceName {
                guard let device = devices.first(where: { $0.name == name }) else {
                    throw SpotifyError.noDevice
                }
                return device.id
            }
            let computers = devices.filter { $0.type == "Computer" }
            guard let device = computers.first(where: { $0.isActive }) ?? computers.first else {
                throw SpotifyError.noDevice
            }
            return device.id
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
            let type: String?
            let name: String?
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
