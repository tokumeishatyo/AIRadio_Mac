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

extension SpotifyController {
    /// 後始末用 pause。キャンセル済み Task 内では URLSession がリクエストを送らずに取り消すため、
    /// キャンセルを継承しない新しい Task で実行して確実に Spotify へ届ける（完全静寂、CLAUDE.md §3-1）。
    /// `restoringVolume` を渡すと停止後にアプリ音量を戻す（ダッキング中の停止で
    /// Spotify が小音量のまま残らないように）。
    public func pauseIgnoringCancellation(restoringVolume: Int? = nil) async {
        let spotify = self
        await Task {
            try? await spotify.pause()
            if let volume = restoringVolume {
                try? await spotify.setVolume(volume)
            }
        }.value
    }
}

extension SpotifyController {
    /// 指定 URI の曲を**終わりまで見届けて**戻る（S10 fix、S12 fix で stale 耐性を強化）。
    /// 1) URI 切替確認: 再生切替直後は `/me/player` が**前の曲のメタデータ**を返すことがあるため、
    ///    切替を確認してから曲長・位置を読む。曲長は **URI と同一スナップショット**の
    ///    `PlayerState.durationSeconds` を使う（別リクエストで取り直すと直前の曲の曲長を掴み、
    ///    前の曲の長さで途中切りする。S12 で実際に踏んだ）。
    /// 2) 残り `marginSeconds` 手前まで待つ。一回のまとめ寝ではなく **`recheckSeconds` 上限の
    ///    チャンクで寝て、起きるたびに位置を読み直す**。snapshot が stale でも次の読み直しで
    ///    自己修正されるため、誤った残り時間を最後まで信じて早切りしない。タイマーの遅延
    ///    （App Nap 等。実測 350 秒寝で +23 秒）があっても読み直し基準なのでデッドエアが伸びない。
    /// 3) 実終端の検知: 「停止 / 別トラックへ遷移 / 再生位置が終端到達 / **位置が進んでいない**」の
    ///    いずれかで即座に戻る。曲が終わっても is_playing=true を返し続ける Spotify の癖があっても、
    ///    位置の停滞（0.5 秒間隔で不変）で確実に抜けられる。
    public func waitForTrackToFinish(
        of uri: String,
        clock: any Clock,
        switchPollSeconds: Double = 0.2,
        switchMaxAttempts: Int = 15,
        marginSeconds: Double = 5,
        endPollSeconds: Double = 0.5,
        recheckSeconds: Double = 30
    ) async throws {
        // 1) URI 切替確認 + 同一スナップショットの曲長・位置
        var duration = 0.0
        var position = 0.0
        for attempt in 0..<switchMaxAttempts {
            let state = try await playerState()
            if state.trackUri == uri {
                duration = state.durationSeconds
                if duration <= 0 {
                    // スナップショットに曲長を持たない実装（AppleScript 等）だけ別問い合わせに倒す。
                    duration = (try? await currentTrackDurationSeconds()) ?? 0
                }
                if duration > 0 {
                    position = state.positionSeconds
                    break
                }
            }
            if attempt < switchMaxAttempts - 1 {
                try await clock.sleep(seconds: switchPollSeconds)
            }
        }

        // 2) 残り margin 手前まで「チャンク寝 → 位置の読み直し」を繰り返す。
        //    budget はリピート再生・位置が進まない異常系での無限待ち防止の安全弁。
        var budget = max(duration - position, 0) + 60
        while duration > 0 {
            let remaining = duration - position
            if remaining <= marginSeconds { break }
            let nap = min(remaining - marginSeconds, recheckSeconds)
            guard budget >= nap else { return }
            try await clock.sleep(seconds: nap)
            budget -= nap

            let state = try await playerState()
            guard state.trackUri == uri else { return }   // 別トラックへ遷移 = この曲は終わった
            if state.state != .playing {
                // 停止に見えても stale の可能性があるため、一拍おいて再確認してから確定する。
                try await clock.sleep(seconds: endPollSeconds)
                let recheck = try await playerState()
                guard recheck.state == .playing, recheck.trackUri == uri else { return }
                position = recheck.positionSeconds
                if recheck.durationSeconds > 0 { duration = recheck.durationSeconds }
                continue
            }
            position = state.positionSeconds
            if state.durationSeconds > 0 { duration = state.durationSeconds }
        }

        // 3) 実終端の検知（margin + 10 秒で打ち切り = 暴走防止の保険）
        var lastPosition = -1.0
        var waited = 0.0
        while waited < marginSeconds + 10 {
            let state = try await playerState()
            guard state.state == .playing, state.trackUri == uri else { return }
            if duration > 0, state.positionSeconds >= duration - 1 { return }
            if state.positionSeconds == lastPosition { return }
            lastPosition = state.positionSeconds
            try await clock.sleep(seconds: endPollSeconds)
            waited += endPollSeconds
        }
    }
}

/// 会話コーナーの準備（LLM 処理、無音）と本番（発話 + 曲）。`CornerEngine` が準拠。
/// 分離により、先行準備（S10）で放送中のデッドエアを避けられる。
public protocol CornerRunning: Sendable {
    func prepare(corner: CornerTemplate, djs: [DjProfile]) async throws -> PreparedCorner
    func run(prepared: PreparedCorner, djs: [DjProfile]) async throws
}

extension CornerRunning {
    /// 準備 + 本番を続けて実行（単発デモ用の互換 API）。
    public func run(corner: CornerTemplate, djs: [DjProfile]) async throws {
        let prepared = try await prepare(corner: corner, djs: djs)
        try await run(prepared: prepared, djs: djs)
    }
}

/// 読み上げ原稿の生成（`NewsWeatherProvider` が準拠。fail-tolerant 前提で throw しない）。
public protocol AnnouncementProviding: Sendable {
    func announcement() async -> String
}

/// 時刻と待機の抽象（テストで差し替え可能にする）。
public protocol Clock: Sendable {
    var now: Date { get }
    func sleep(seconds: Double) async throws
}
