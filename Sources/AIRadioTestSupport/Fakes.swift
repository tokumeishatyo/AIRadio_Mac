import Foundation
import AIRadioCore

// MARK: - ステートレス fake（struct, Sendable）

/// プロンプトをそのままエコーする LLM。
public struct EchoLLM: LLMBackend {
    public init() {}
    public func generate(_ request: LLMRequest) async throws -> String {
        "echo: " + request.prompt
    }
}

/// テキストと話者 ID から決定論的なダミー WAV データを返す TTS。
public struct InMemoryTTS: TTSBackend {
    public init() {}
    public func synthesize(text: String, speakerId: Int) async throws -> Data {
        Data("\(speakerId):\(text)".utf8)
    }
}

/// 固定時刻・即時 sleep の Clock。
public struct FakeClock: Clock {
    public let now: Date
    public init(now: Date = Date(timeIntervalSince1970: 0)) { self.now = now }
    public func sleep(seconds: Double) async throws { /* 即時（待たない） */ }
}

/// 固定ペイロードを返す ResearchSource。
public struct FakeResearchSource: ResearchSource {
    public let payload: String
    public init(payload: String) { self.payload = payload }
    public func fetch() async throws -> String { payload }
}

// MARK: - 記録 fake（呼び出しを記録、final class + ロックで Sendable 保証）

/// 用意した応答を順番に返し、リクエストを記録する LLM。応答が尽きたら emptyResponse。
public final class ScriptedLLM: LLMBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _responses: [String]
    private var _requests: [LLMRequest] = []
    public init(responses: [String]) { _responses = responses }
    public var requests: [LLMRequest] { lock.withLock { _requests } }
    public func generate(_ request: LLMRequest) async throws -> String {
        try lock.withLock {
            _requests.append(request)
            guard !_responses.isEmpty else { throw LLMError.emptyResponse }
            return _responses.removeFirst()
        }
    }
}

/// テーマ演出の実行を記録する ThemeSequencing（演出はしない）。
public final class SpyThemeSequencer: ThemeSequencing, @unchecked Sendable {
    public struct Run: Sendable, Equatable {
        public let trackUri: String
        public let announcement: String
        public let speakerId: Int
        public init(trackUri: String, announcement: String, speakerId: Int) {
            self.trackUri = trackUri
            self.announcement = announcement
            self.speakerId = speakerId
        }
    }
    private let lock = NSLock()
    private var _runs: [Run] = []
    public init() {}
    public var runs: [Run] { lock.withLock { _runs } }
    public func run(theme: ThemeConfig, announcement: String, speakerId: Int) async throws {
        lock.withLock {
            _runs.append(Run(trackUri: theme.trackUri, announcement: announcement, speakerId: speakerId))
        }
    }
}

/// コーナーの準備・実行を記録する CornerRunning。コーナー id ごとにエラーを注入できる（prepare で投げる）。
public final class FakeCornerRunner: CornerRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _preparedCornerIds: [String] = []
    private var _ranCornerIds: [String] = []
    private var _ranPrepared: [PreparedCorner] = []
    private let errors: [String: any Error & Sendable]
    public init(errors: [String: any Error & Sendable] = [:]) { self.errors = errors }
    public var preparedCornerIds: [String] { lock.withLock { _preparedCornerIds } }
    public var ranCornerIds: [String] { lock.withLock { _ranCornerIds } }
    public var ranPrepared: [PreparedCorner] { lock.withLock { _ranPrepared } }

    public func prepare(corner: CornerTemplate, djs: [DjProfile]) async throws -> PreparedCorner {
        lock.withLock { _preparedCornerIds.append(corner.id) }
        if let error = errors[corner.id] { throw error }
        return PreparedCorner(
            corner: corner,
            song: TrackInfo(uri: "spotify:track:PREPARED-\(corner.id)", title: "T", artist: "A"),
            script: DialogueScript(lines: [DialogueLine(djId: corner.djIds.first ?? "", text: "準備済み")])
        )
    }

    public func run(prepared: PreparedCorner, djs: [DjProfile]) async throws {
        lock.withLock {
            _ranCornerIds.append(prepared.corner.id)
            _ranPrepared.append(prepared)
        }
    }
}

/// 固定の選曲結果（またはエラー）を返す SongPicking。依頼内容を記録する。
public final class FakeSongPicker: SongPicking, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [SongRequest] = []
    private let result: Result<TrackInfo, any Error>
    public init(track: TrackInfo) { result = .success(track) }
    public init(error: any Error & Sendable) { result = .failure(error) }
    public var requests: [SongRequest] { lock.withLock { _requests } }
    public func pick(_ request: SongRequest) async throws -> TrackInfo {
        lock.withLock { _requests.append(request) }
        return try result.get()
    }
}

/// 固定原稿を返す AnnouncementProviding。
public struct FakeAnnouncementProvider: AnnouncementProviding {
    public let script: String
    public init(script: String) { self.script = script }
    public func announcement() async -> String { script }
}

/// 再生された WAV を記録する AudioPlayer。
public final class SpyAudioPlayer: AudioPlayer, @unchecked Sendable {
    private let lock = NSLock()
    private var _played: [Data] = []
    public init() {}
    public var played: [Data] { lock.withLock { _played } }
    public func play(_ wav: Data) async throws {
        lock.withLock { _played.append(wav) }
    }
}

/// 検索クエリを記録し、設定済み結果を返す TrackSearcher。
public final class FakeTrackSearcher: TrackSearcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _results: [TrackInfo]
    private var _queries: [String] = []
    public init(results: [TrackInfo] = []) { _results = results }
    public var queries: [String] { lock.withLock { _queries } }
    public func search(query: String, limit: Int) async throws -> [TrackInfo] {
        lock.withLock {
            _queries.append(query)
            return Array(_results.prefix(limit))
        }
    }
    public func isPlayable(_ uri: String) async throws -> Bool {
        lock.withLock { _results.first { $0.uri == uri }?.isPlayable ?? false }
    }
}

/// Spotify 制御の呼び出し順を記録する SpotifyController。
public enum SpotifyEvent: Sendable, Equatable {
    case play(String)
    case pause
    case setVolume(Int)
    case seek(Int)
}

public final class FakeSpotifyController: SpotifyController, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [SpotifyEvent] = []
    private var _state: PlayerState
    private let _duration: Double
    public init(state: PlayerState = PlayerState(state: .stopped), durationSeconds: Double = 0) {
        _state = state
        _duration = durationSeconds
    }
    public var events: [SpotifyEvent] { lock.withLock { _events } }
    public func play(uri: String) async throws {
        lock.withLock {
            _events.append(.play(uri))
            _state = PlayerState(state: .playing, trackUri: uri, positionSeconds: 0, durationSeconds: _duration)
        }
    }
    public func pause() async throws { lock.withLock { _events.append(.pause) } }
    public func setVolume(_ percent: Int) async throws { lock.withLock { _events.append(.setVolume(percent)) } }
    public func seek(toSeconds seconds: Int) async throws { lock.withLock { _events.append(.seek(seconds)) } }
    public func playerState() async throws -> PlayerState { lock.withLock { _state } }
    public func currentTrackDurationSeconds() async throws -> Double { _duration }
}

/// 仮想時間で再生位置が進む Spotify + Clock のシミュレータ（フル再生の終端検知テスト用）。
/// `sleep` が仮想時間を進め、`playerState` は再生開始からの経過 = 再生位置を返す。
/// `SpotifyController` と `Clock` の両方に同じインスタンスを渡して使う。
public final class PlaybackSimulator: SpotifyController, Clock, @unchecked Sendable {
    private let lock = NSLock()
    private let durations: [String: Double]
    /// false = スナップショットに曲長を含めない実装（AppleScript 等の互換パス）を再現。
    private let snapshotIncludesDuration: Bool
    /// `currentTrackDurationSeconds()`（別問い合わせ）が返す値の上書き。stale な曲長の注入用。
    private let legacyDurationOverride: Double?
    /// `playerState()` が最初に返す stale スナップショット列（切替直後の前曲応答などの再現）。
    private var staleSnapshots: [PlayerState]
    /// `playerState()` の n 回目（1 始まり）の応答を stale に差し替える（再生途中の stale 混入の再現）。
    private let staleByCall: [Int: PlayerState]
    private var stateCalls = 0
    private var virtualTime: Double = 0
    private var currentUri: String?
    private var startedAt: Double = 0
    private var pausedFlag = true
    private var _sleeps: [Double] = []
    private var _events: [SpotifyEvent] = []

    public init(
        durations: [String: Double],
        snapshotIncludesDuration: Bool = true,
        legacyDurationOverride: Double? = nil,
        staleSnapshots: [PlayerState] = [],
        staleByCall: [Int: PlayerState] = [:]
    ) {
        self.durations = durations
        self.snapshotIncludesDuration = snapshotIncludesDuration
        self.legacyDurationOverride = legacyDurationOverride
        self.staleSnapshots = staleSnapshots
        self.staleByCall = staleByCall
    }

    public var sleeps: [Double] { lock.withLock { _sleeps } }
    public var events: [SpotifyEvent] { lock.withLock { _events } }
    /// 現在の仮想再生位置（テストの検証用）。
    public var currentPositionSeconds: Double { lock.withLock { positionLocked() } }

    // MARK: Clock

    public var now: Date { lock.withLock { Date(timeIntervalSince1970: virtualTime) } }
    public func sleep(seconds: Double) async throws {
        lock.withLock {
            _sleeps.append(seconds)
            virtualTime += max(seconds, 0)
        }
    }

    // MARK: SpotifyController

    public func play(uri: String) async throws {
        lock.withLock {
            _events.append(.play(uri))
            currentUri = uri
            startedAt = virtualTime
            pausedFlag = false
        }
    }
    public func pause() async throws { lock.withLock { _events.append(.pause); pausedFlag = true } }
    public func setVolume(_ percent: Int) async throws { lock.withLock { _events.append(.setVolume(percent)) } }
    public func seek(toSeconds seconds: Int) async throws {
        lock.withLock {
            _events.append(.seek(seconds))
            startedAt = virtualTime - Double(seconds)
        }
    }

    public func playerState() async throws -> PlayerState {
        lock.withLock {
            stateCalls += 1
            if let stale = staleByCall[stateCalls] { return stale }
            if !staleSnapshots.isEmpty { return staleSnapshots.removeFirst() }
            guard let uri = currentUri, !pausedFlag else {
                return PlayerState(state: currentUri == nil ? .stopped : .paused, trackUri: currentUri)
            }
            let duration = durations[uri] ?? 0
            let position = positionLocked()
            // 曲の終端に達したら自然停止（paused）として観測される。
            if duration > 0, position >= duration {
                return PlayerState(
                    state: .paused, trackUri: uri, positionSeconds: duration,
                    durationSeconds: snapshotIncludesDuration ? duration : 0)
            }
            return PlayerState(
                state: .playing, trackUri: uri, positionSeconds: position,
                durationSeconds: snapshotIncludesDuration ? duration : 0)
        }
    }

    public func currentTrackDurationSeconds() async throws -> Double {
        lock.withLock {
            if let override = legacyDurationOverride { return override }
            guard let uri = currentUri else { return 0 }
            return durations[uri] ?? 0
        }
    }

    private func positionLocked() -> Double {
        guard let uri = currentUri else { return 0 }
        let elapsed = virtualTime - startedAt
        let duration = durations[uri] ?? 0
        return duration > 0 ? min(elapsed, duration) : elapsed
    }
}
