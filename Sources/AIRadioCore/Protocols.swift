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

/// `waitForTrackToFinish` の復帰理由（診断ログ用。途中切り調査で常時可視化、S12 fix-2）。
public enum TrackFinishReason: String, Sendable {
    /// 再生停止を 2 回連続で確認（曲の自然終了 or 外部からの停止）
    case stopped
    /// 別トラックへの遷移を 2 回連続で確認
    case trackChanged
    /// 再生位置が終端に到達
    case reachedEnd
    /// 終端付近で位置が停滞（曲は実質終わっている）
    case positionStalled
    /// 安全弁による打ち切り（待ち時間の上限到達。位置が進まない・切替未確認等の異常系）
    case timedOut
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
    ///    いずれかで戻る。曲が終わっても is_playing=true を返し続ける Spotify の癖があっても、
    ///    位置の停滞（0.5 秒間隔で不変）で確実に抜けられる。
    ///
    /// **終了らしき観測はすべて二重確認する（S12 fix-2）**: `/me/player` は再生中でも稀に stale な
    /// スナップショット（前の曲・paused 等）を返すことが実測されている。「別トラックに遷移した」
    /// 「停止した」を 1 回の観測で確定すると、その瞬間に呼び出し側の pause が走って曲の途中切りになる。
    /// 一拍（`endPollSeconds`）おいた再観測でも同じ結論のときだけ終了と確定する。
    /// 戻り値は復帰理由（診断ログ用）。
    @discardableResult
    public func waitForTrackToFinish(
        of uri: String,
        clock: any Clock,
        switchPollSeconds: Double = 0.2,
        switchMaxAttempts: Int = 15,
        marginSeconds: Double = 5,
        endPollSeconds: Double = 0.5,
        recheckSeconds: Double = 30
    ) async throws -> TrackFinishReason {
        // 終了らしき観測の二重確認。終了なら理由を、stale（再観測で再生中）なら nil + 最新状態を返す。
        func confirmEnd(after first: PlayerState) async throws -> (reason: TrackFinishReason?, latest: PlayerState) {
            if first.state == .playing, first.trackUri == uri { return (nil, first) }
            try await clock.sleep(seconds: endPollSeconds)
            let second = try await playerState()
            if second.state == .playing, second.trackUri == uri { return (nil, second) }  // stale を踏んだだけ
            if let other = second.trackUri, other != uri { return (.trackChanged, second) }
            return (.stopped, second)
        }

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
            guard budget >= nap else { return .timedOut }
            try await clock.sleep(seconds: nap)
            budget -= nap

            let observed = try await playerState()
            let (reason, latest) = try await confirmEnd(after: observed)
            if let reason { return reason }
            position = latest.positionSeconds
            if latest.durationSeconds > 0 { duration = latest.durationSeconds }
        }

        // 3) 実終端の検知（margin + 10 秒で打ち切り = 暴走防止の保険）
        var lastPosition = -1.0
        var waited = 0.0
        while waited < marginSeconds + 10 {
            let observed = try await playerState()
            let (reason, latest) = try await confirmEnd(after: observed)
            if let reason { return reason }
            if duration > 0, latest.positionSeconds >= duration - 1 { return .reachedEnd }
            if latest.positionSeconds == lastPosition { return .positionStalled }
            lastPosition = latest.positionSeconds
            try await clock.sleep(seconds: endPollSeconds)
            waited += endPollSeconds
        }
        return .timedOut
    }
}

/// 会話コーナーの準備（LLM 処理、無音）と本番（発話 + 曲）。`CornerEngine` が準拠。
/// 分離により、先行準備（S10）で放送中のデッドエアを避けられる。
public protocol CornerRunning: Sendable {
    func prepare(corner: CornerTemplate, djs: [DjProfile], context: CornerContext) async throws -> PreparedCorner
    func run(prepared: PreparedCorner, djs: [DjProfile]) async throws
}

extension CornerRunning {
    /// 準備 + 本番を続けて実行（単発デモ用の互換 API。既定コンテキスト＝編成は corner 定義・挨拶/リード文なし）。
    public func run(corner: CornerTemplate, djs: [DjProfile], context: CornerContext = CornerContext()) async throws {
        let prepared = try await prepare(corner: corner, djs: djs, context: context)
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
