import Foundation
import Testing
import AIRadioCore
import AIRadioTestSupport

private let djs = [
    DjProfile(id: "zundamon", name: "ずんだもん", speakerId: 3, persona: ""),
    DjProfile(id: "metan", name: "四国めたん", speakerId: 2, persona: ""),
]

private let freeTalk = CornerTemplate(
    id: "free_talk", title: "フリートーク", theme: "テーマ",
    djIds: ["zundamon", "metan"], fallbackTrackUri: "spotify:track:FALLBACK"
)
private let letterCorner = CornerTemplate(
    id: "letter", title: "お便り", theme: "テーマ", format: .letter,
    djIds: ["zundamon", "metan"], fallbackTrackUri: "spotify:track:FALLBACK"
)
private let corners = [freeTalk, letterCorner]

private func theme(_ uri: String) -> ThemeConfig {
    ThemeConfig(tagline: nil, trackUri: uri, introSeconds: 5, volume: 85, duckedVolume: 35, outroSeconds: 10)
}

private let themes = BroadcastThemes(
    opening: ThemedAnnouncement(theme: theme("spotify:track:OP"), announcement: "オープニングです"),
    news: theme("spotify:track:NEWS"),
    ending: ThemedAnnouncement(theme: theme("spotify:track:ED"), announcement: "エンディングです")
)

private func blueprint(
    talkCornerId: String = "free_talk",
    openingCritical: Bool = true,
    songPlaySeconds: Int = 45
) -> ProgramBlueprint {
    ProgramBlueprint(
        title: "テスト番組",
        anchorDjId: "zundamon",
        openingCritical: openingCritical,
        song: SongSegmentSpec(
            promptHint: "幕開けの曲", fallbackTrackUri: "spotify:track:SONGFALLBACK",
            volume: 100, playSeconds: songPlaySeconds),
        talkCornerId: talkCornerId,
        letterCornerId: "letter"
    )
}

/// N=2 の標準プラン: OP(0) song(1) talk(2) talk(3) letter(4) news(5) ED(6)。
private func plan(_ n: Int) -> ProgramPlan {
    ProgramPlan(blueprint: blueprint(), length: .corners(n))
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [BroadcastEvent] = []
    var events: [BroadcastEvent] { lock.withLock { _events } }
    func append(_ event: BroadcastEvent) { lock.withLock { _events.append(event) } }
}

private struct Fixture {
    let sequencer = SpyThemeSequencer()
    let cornerRunner: FakeCornerRunner
    let spotify = FakeSpotifyController()
    let recorder = EventRecorder()
    let engine: BroadcastEngine

    init(cornerErrors: [String: any Error & Sendable] = [:], newsScript: String = "ニュース原稿") {
        cornerRunner = FakeCornerRunner(errors: cornerErrors)
        let recorder = self.recorder
        engine = BroadcastEngine(
            themes: themes,
            themeSequencer: sequencer,
            cornerRunner: cornerRunner,
            newsProvider: FakeAnnouncementProvider(script: newsScript),
            spotify: spotify,
            clock: FakeClock(),
            onEvent: { recorder.append($0) }
        )
    }
}

@Suite("BroadcastEngine")
struct BroadcastEngineTests {
    @Test("正常系（N=2）: OP → 冒頭曲 → t1 t2 → お便り → ニュース → ED の順に実行し、最後に pause")
    func happyPathRunsInOrder() async throws {
        let fixture = Fixture()
        try await fixture.engine.run(plan: plan(2), corners: corners, djs: djs)

        // テーマ演出: OP → ニュース（実行時原稿） → ED の順、読み上げはアンカー DJ（ずんだもん=3）。
        #expect(fixture.sequencer.runs == [
            SpyThemeSequencer.Run(trackUri: "spotify:track:OP", announcement: "オープニングです", speakerId: 3),
            SpyThemeSequencer.Run(trackUri: "spotify:track:NEWS", announcement: "ニュース原稿", speakerId: 3),
            SpyThemeSequencer.Run(trackUri: "spotify:track:ED", announcement: "エンディングです", speakerId: 3),
        ])
        // コーナーはトーク 2 本 → お便りの順。
        #expect(fixture.cornerRunner.ranCornerIds == ["free_talk", "free_talk", "letter"])
        #expect(fixture.spotify.events.contains(.pause))
        #expect(fixture.recorder.events.first == .segmentStarted(index: 0, kind: .opening))
        #expect(fixture.recorder.events.contains(.segmentFinished(index: 6, kind: .ending)))
        #expect(fixture.recorder.events.last == .broadcastFinished)
    }

    @Test("セグメント失敗はスキップして放送継続（トーク失敗でもお便り・ニュース・ED は実行）")
    func skipsFailedSegmentAndContinues() async throws {
        let fixture = Fixture(cornerErrors: ["free_talk": LLMError.emptyResponse])
        try await fixture.engine.run(plan: plan(2), corners: corners, djs: djs)

        #expect(fixture.recorder.events.contains(
            .segmentFailed(index: 2, kind: .talk, code: "E-LLM-EMPTY-RESPONSE-001",
                           detail: LLMError.emptyResponse.message)))
        #expect(fixture.cornerRunner.ranCornerIds == ["letter"])
        #expect(fixture.sequencer.runs.count == 3)
        #expect(fixture.recorder.events.last == .broadcastFinished)
        #expect(fixture.spotify.events.contains(.pause))
    }

    @Test("キャンセルは即時伝播: 後続セグメントは実行せず、必ず pause、broadcastFinished なし")
    func cancellationStopsImmediately() async {
        let fixture = Fixture(cornerErrors: ["free_talk": CancellationError()])
        await #expect(throws: CancellationError.self) {
            try await fixture.engine.run(plan: plan(2), corners: corners, djs: djs)
        }
        // OP のみ実行済み。news / ending には進まない。
        #expect(fixture.sequencer.runs.count == 1)
        #expect(fixture.spotify.events.contains(.pause))
        #expect(!fixture.recorder.events.contains(.broadcastFinished))
    }

    @Test("キャンセル中のラップ済みエラー（例: Spotify auth 失敗）もスキップせず即時停止")
    func wrappedErrorDuringCancellationStopsImmediately() async {
        // Infra 層は URLSession の取消をドメインエラーにラップすることがある。
        // タスクがキャンセル済みなら、それをセグメント失敗と誤判定してはならない。
        struct SelfCancellingRunner: CornerRunning {
            func prepare(corner: CornerTemplate, djs: [DjProfile]) async throws -> PreparedCorner {
                PreparedCorner(corner: corner, song: TrackInfo(uri: "x", title: "", artist: ""),
                               script: DialogueScript(lines: []))
            }
            func run(prepared: PreparedCorner, djs: [DjProfile]) async throws {
                withUnsafeCurrentTask { $0?.cancel() }
                throw SpotifyError.authFailed("request cancelled")
            }
        }
        let sequencer = SpyThemeSequencer()
        let spotify = FakeSpotifyController()
        let recorder = EventRecorder()
        let engine = BroadcastEngine(
            themes: themes,
            themeSequencer: sequencer,
            cornerRunner: SelfCancellingRunner(),
            newsProvider: FakeAnnouncementProvider(script: "x"),
            spotify: spotify,
            clock: FakeClock(),
            onEvent: { recorder.append($0) }
        )
        await #expect(throws: CancellationError.self) {
            try await engine.run(plan: plan(2), corners: corners, djs: djs)
        }
        // talk の後の news / ending には進まない（OP の 1 回のみ）。
        #expect(sequencer.runs.count == 1)
        #expect(!recorder.events.contains { event in
            if case .segmentFailed = event { return true } else { return false }
        })
        #expect(spotify.events.contains(.pause))
    }

    @Test("critical セグメント（OP）の失敗は放送中止（スキップしない、Windows 版踏襲）")
    func criticalSegmentFailureAbortsBroadcast() async {
        struct FailingSequencer: ThemeSequencing {
            func run(theme: ThemeConfig, announcement: String, speakerId: Int) async throws {
                throw SpotifyError.authFailed("token expired")
            }
        }
        let spotify = FakeSpotifyController()
        let recorder = EventRecorder()
        let cornerRunner = FakeCornerRunner()
        let engine = BroadcastEngine(
            themes: themes,
            themeSequencer: FailingSequencer(),
            cornerRunner: cornerRunner,
            newsProvider: FakeAnnouncementProvider(script: "x"),
            spotify: spotify,
            clock: FakeClock(),
            onEvent: { recorder.append($0) }
        )
        await #expect(throws: BroadcastError.self) {
            try await engine.run(plan: plan(2), corners: corners, djs: djs)
        }
        // OP 失敗で中止: talk には進まず、失敗イベントは通知され、pause で静寂。
        #expect(cornerRunner.ranCornerIds.isEmpty)
        #expect(recorder.events.contains(
            .segmentFailed(index: 0, kind: .opening, code: "E-SPT-AUTH-FAILED-001",
                           detail: SpotifyError.authFailed("token expired").message)))
        #expect(!recorder.events.contains(.broadcastFinished))
        #expect(spotify.events.contains(.pause))
    }

    @Test("キャンセル中でも後始末の pause が実行される（キャンセル非継承の Task で送る）")
    func cleanupPauseSurvivesCancellation() async {
        // キャンセル済み Task 内の URLSession はリクエストを送らない問題の再発防止。
        // pause が「キャンセルされていない文脈」で呼ばれることを検証する。
        final class CancellationSensingSpotify: SpotifyController, @unchecked Sendable {
            private let lock = NSLock()
            private var _pauseCancelledFlags: [Bool] = []
            var pauseCancelledFlags: [Bool] { lock.withLock { _pauseCancelledFlags } }
            func play(uri: String) async throws {}
            func pause() async throws {
                let cancelled = Task.isCancelled
                lock.withLock { _pauseCancelledFlags.append(cancelled) }
            }
            func setVolume(_ percent: Int) async throws {}
            func seek(toSeconds seconds: Int) async throws {}
            func playerState() async throws -> PlayerState { PlayerState(state: .playing) }
            func currentTrackDurationSeconds() async throws -> Double { 0 }
        }
        struct SelfCancellingRunner: CornerRunning {
            func prepare(corner: CornerTemplate, djs: [DjProfile]) async throws -> PreparedCorner {
                PreparedCorner(corner: corner, song: TrackInfo(uri: "x", title: "", artist: ""),
                               script: DialogueScript(lines: []))
            }
            func run(prepared: PreparedCorner, djs: [DjProfile]) async throws {
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
        }
        let spotify = CancellationSensingSpotify()
        let engine = BroadcastEngine(
            themes: themes,
            themeSequencer: SpyThemeSequencer(),
            cornerRunner: SelfCancellingRunner(),
            newsProvider: FakeAnnouncementProvider(script: "x"),
            spotify: spotify,
            clock: FakeClock()
        )
        await #expect(throws: CancellationError.self) {
            try await engine.run(plan: plan(2), corners: corners, djs: djs)
        }
        #expect(!spotify.pauseCancelledFlags.isEmpty)
        #expect(spotify.pauseCancelledFlags.allSatisfy { $0 == false })
    }

    @Test("song セグメント: 先行選曲した曲を再生し、OP の {first_song} で曲振りされる")
    func songSegmentPlaysPickedTrackAndFeedsOpening() async throws {
        let songThemes = BroadcastThemes(
            opening: ThemedAnnouncement(
                theme: theme("spotify:track:OP"),
                announcement: "それでは聴いてください。{first_song}。"),
            news: theme("spotify:track:NEWS"),
            ending: ThemedAnnouncement(theme: theme("spotify:track:ED"), announcement: "ED")
        )
        let picker = FakeSongPicker(track: TrackInfo(uri: "spotify:track:FIRST", title: "夜に駆ける", artist: "YOASOBI"))
        let sequencer = SpyThemeSequencer()
        let spotify = FakeSpotifyController()
        let recorder = EventRecorder()
        let engine = BroadcastEngine(
            themes: songThemes,
            themeSequencer: sequencer,
            cornerRunner: FakeCornerRunner(),
            newsProvider: FakeAnnouncementProvider(script: "x"),
            songPicker: picker,
            spotify: spotify,
            clock: FakeClock(),
            onEvent: { recorder.append($0) }
        )
        try await engine.run(plan: plan(1), corners: corners, djs: djs)

        // OP の曲振りに確定曲が入る。
        #expect(sequencer.runs[0].announcement == "それでは聴いてください。YOASOBIで、「夜に駆ける」。")
        // song セグメント: 再生 → 音量 → pause（playSeconds=45 の固定再生）。
        #expect(spotify.events.prefix(3) == [.play("spotify:track:FIRST"), .setVolume(100), .pause])
        #expect(recorder.events.contains(
            .songStarted(index: 1, track: TrackInfo(uri: "spotify:track:FIRST", title: "夜に駆ける", artist: "YOASOBI"))))
        // 選曲依頼にヒントが渡る。
        #expect(picker.requests.first?.promptHint == "幕開けの曲")
    }

    @Test("選曲失敗・picker なしはフォールバック曲に倒し、曲振りは「本日の一曲」")
    func songSegmentFallsBackOnPickerFailure() async throws {
        let songThemes = BroadcastThemes(
            opening: ThemedAnnouncement(
                theme: theme("spotify:track:OP"), announcement: "{first_song}。"),
            news: theme("spotify:track:NEWS"),
            ending: ThemedAnnouncement(theme: theme("spotify:track:ED"), announcement: "ED")
        )
        let sequencer = SpyThemeSequencer()
        let spotify = FakeSpotifyController()
        let engine = BroadcastEngine(
            themes: songThemes,
            themeSequencer: sequencer,
            cornerRunner: FakeCornerRunner(),
            newsProvider: FakeAnnouncementProvider(script: "x"),
            songPicker: FakeSongPicker(error: LLMError.emptyResponse),
            spotify: spotify,
            clock: FakeClock()
        )
        try await engine.run(plan: plan(1), corners: corners, djs: djs)
        #expect(sequencer.runs[0].announcement == "本日の一曲。")
        #expect(spotify.events.contains(.play("spotify:track:SONGFALLBACK")))
    }

    @Test("song フル再生: 切替直後のメタデータ遅延でも前の曲の長さで早切りしない")
    func songFullPlaybackWaitsForMetadataSwitch() async throws {
        // 最初の 2 回は前の曲（OP テーマ、30 秒）のメタデータを返し、3 回目から新曲（240 秒）。
        final class LaggySpotify: SpotifyController, @unchecked Sendable {
            private let lock = NSLock()
            private var stateQueries = 0
            private var switched = false
            func play(uri: String) async throws {}
            func pause() async throws {}
            func setVolume(_ percent: Int) async throws {}
            func seek(toSeconds seconds: Int) async throws {}
            func playerState() async throws -> PlayerState {
                lock.withLock {
                    stateQueries += 1
                    if stateQueries >= 3 { switched = true }
                    return PlayerState(
                        state: .playing,
                        trackUri: switched ? "spotify:track:FIRST" : "spotify:track:OP-THEME",
                        positionSeconds: 0
                    )
                }
            }
            func currentTrackDurationSeconds() async throws -> Double {
                lock.withLock { switched ? 240 : 30 }
            }
        }
        final class SleepRecorder: Clock, @unchecked Sendable {
            private let lock = NSLock()
            private var _sleeps: [Double] = []
            let now = Date(timeIntervalSince1970: 0)
            var sleeps: [Double] { lock.withLock { _sleeps } }
            func sleep(seconds: Double) async throws { lock.withLock { _sleeps.append(seconds) } }
        }
        let clock = SleepRecorder()
        let engine = BroadcastEngine(
            themes: themes,
            themeSequencer: SpyThemeSequencer(),
            cornerRunner: FakeCornerRunner(),
            newsProvider: FakeAnnouncementProvider(script: "x"),
            songPicker: FakeSongPicker(track: TrackInfo(uri: "spotify:track:FIRST", title: "T", artist: "A")),
            spotify: LaggySpotify(),
            clock: clock
        )
        // N=0: OP → song（フル再生）→ ED のみ。
        let fullPlayPlan = ProgramPlan(
            blueprint: blueprint(songPlaySeconds: 0), length: .corners(0))
        try await engine.run(plan: fullPlayPlan, corners: corners, djs: djs)
        // ポーリング（0.2s × 2）の後、新曲の曲長（240 秒）基準で待つ（前の曲の 30 秒側で早切りしない）。
        let napped = clock.sleeps.filter { $0 > 1 }.reduce(0, +)
        #expect(napped >= 235)
        #expect(!clock.sleeps.contains(25))   // 前の曲（30 秒）基準のまとめ寝をしない
    }

    @Test("曲終了後も is_playing=true が返り続けても、位置の停滞で即座に次へ進む")
    func detectsTrackEndByFrozenPosition() async throws {
        // 終端で再生位置が止まったまま is_playing=true を返し続ける Spotify の癖を再現。
        final class FrozenAtEndSpotify: SpotifyController, @unchecked Sendable {
            private let lock = NSLock()
            private var positions: [Double] = [195, 198, 198, 198, 198, 198]  // 198 で停滞
            func play(uri: String) async throws {}
            func pause() async throws {}
            func setVolume(_ percent: Int) async throws {}
            func seek(toSeconds seconds: Int) async throws {}
            func playerState() async throws -> PlayerState {
                lock.withLock {
                    let position = positions.isEmpty ? 198 : positions.removeFirst()
                    return PlayerState(state: .playing, trackUri: "spotify:track:FIRST", positionSeconds: position)
                }
            }
            func currentTrackDurationSeconds() async throws -> Double { 200 }
        }
        final class SleepRecorder: Clock, @unchecked Sendable {
            private let lock = NSLock()
            private var _sleeps: [Double] = []
            let now = Date(timeIntervalSince1970: 0)
            var sleeps: [Double] { lock.withLock { _sleeps } }
            func sleep(seconds: Double) async throws { lock.withLock { _sleeps.append(seconds) } }
        }
        let clock = SleepRecorder()
        let engine = BroadcastEngine(
            themes: themes,
            themeSequencer: SpyThemeSequencer(),
            cornerRunner: FakeCornerRunner(),
            newsProvider: FakeAnnouncementProvider(script: "x"),
            songPicker: FakeSongPicker(track: TrackInfo(uri: "spotify:track:FIRST", title: "T", artist: "A")),
            spotify: FrozenAtEndSpotify(),
            clock: clock
        )
        let fullPlayPlan = ProgramPlan(
            blueprint: blueprint(songPlaySeconds: 0), length: .corners(0))
        try await engine.run(plan: fullPlayPlan, corners: corners, djs: djs)
        // 上限（margin+10 秒 = 0.5s × 20 ポーリング）まで粘らず、位置停滞の検知で数回のうちに抜ける。
        let endPolls = clock.sleeps.filter { $0 == 0.5 }
        #expect(endPolls.count <= 3)
    }

    @Test("news は出現のたびに生成される（N=4 はニュース 2 回 = 原稿 2 回生成、s13 §3）")
    func newsScriptIsGeneratedPerOccurrence() async throws {
        final class CountingProvider: AnnouncementProviding, @unchecked Sendable {
            private let lock = NSLock()
            private var _calls = 0
            var calls: Int { lock.withLock { _calls } }
            func announcement() async -> String {
                lock.withLock { _calls += 1 }
                return "原稿"
            }
        }
        let provider = CountingProvider()
        let sequencer = SpyThemeSequencer()
        let engine = BroadcastEngine(
            themes: themes,
            themeSequencer: sequencer,
            cornerRunner: FakeCornerRunner(),
            newsProvider: provider,
            spotify: FakeSpotifyController(),
            clock: FakeClock()
        )
        try await engine.run(plan: plan(4), corners: corners, djs: djs)
        #expect(provider.calls == 2)
        // OP + news×2 + ED = テーマ演出 4 回。
        #expect(sequencer.runs.count == 4)
        #expect(sequencer.runs[1].announcement == "原稿")
        #expect(sequencer.runs[2].announcement == "原稿")
    }

    @Test("talk の準備は先行起動され、本番は準備済み成果物で実行される")
    func talkUsesPreparedContent() async throws {
        let fixture = Fixture()
        try await fixture.engine.run(plan: plan(1), corners: corners, djs: djs)
        #expect(fixture.cornerRunner.preparedCornerIds == ["free_talk"])
        // run(prepared:) に prepare の成果物がそのまま渡る（本番での LLM 再実行なし）。
        #expect(fixture.cornerRunner.ranPrepared.map(\.song.uri) == ["spotify:track:PREPARED-free_talk"])
    }

    @Test("停止時は先行準備タスクもキャンセルされる")
    func cancellationCancelsPreparations() async {
        final class BlockingPrepareRunner: CornerRunning, @unchecked Sendable {
            private let lock = NSLock()
            private var _sawCancellation = false
            var sawCancellation: Bool { lock.withLock { _sawCancellation } }
            func prepare(corner: CornerTemplate, djs: [DjProfile]) async throws -> PreparedCorner {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                lock.withLock { _sawCancellation = true }
                throw CancellationError()
            }
            func run(prepared: PreparedCorner, djs: [DjProfile]) async throws {}
        }
        let runner = BlockingPrepareRunner()
        let engine = BroadcastEngine(
            themes: themes,
            themeSequencer: SpyThemeSequencer(),
            cornerRunner: runner,
            newsProvider: FakeAnnouncementProvider(script: "x"),
            spotify: FakeSpotifyController(),
            clock: FakeClock()
        )
        let broadcast = Task {
            try await engine.run(plan: plan(1), corners: corners, djs: djs)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        broadcast.cancel()
        let result = await broadcast.result
        if case .failure(let error) = result {
            #expect(error is CancellationError)
        } else {
            Issue.record("キャンセルで失敗するはず")
        }
        // 準備タスクがキャンセルを観測するまで待つ（非同期完了）。
        for _ in 0..<100 {
            if runner.sawCancellation { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(runner.sawCancellation)
    }

    @Test("未定義の corner_id / news dj_id は fail-fast（音を出す前に設定エラー）")
    func unknownReferencesFailFast() async {
        let fixture = Fixture()
        let brokenCorner = ProgramPlan(
            blueprint: blueprint(talkCornerId: "unknown"), length: .corners(2))
        await #expect(throws: ConfigError.self) {
            try await fixture.engine.run(plan: brokenCorner, corners: corners, djs: djs)
        }
        var withUnknownDj = blueprint()
        withUnknownDj.newsDjId = "unknown"
        await #expect(throws: ConfigError.self) {
            try await fixture.engine.run(
                plan: ProgramPlan(blueprint: withUnknownDj, length: .corners(2)),
                corners: corners, djs: djs)
        }
        #expect(fixture.sequencer.runs.isEmpty)
    }

    @Test("時刻プレースホルダを発話直前に展開（OP は挨拶+日付+NHK 式、ニュースは 12 時間表記）")
    func expandsTimePlaceholders() async throws {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 12, hour: 15, minute: 7))!

        let timeThemes = BroadcastThemes(
            opening: ThemedAnnouncement(
                theme: theme("spotify:track:OP"),
                announcement: "{greeting}。{month}月{day}日、{ampm}{hour}時になりました。"),
            news: theme("spotify:track:NEWS"),
            ending: ThemedAnnouncement(theme: theme("spotify:track:ED"), announcement: "ED")
        )
        let sequencer = SpyThemeSequencer()
        let engine = BroadcastEngine(
            themes: timeThemes,
            themeSequencer: sequencer,
            cornerRunner: FakeCornerRunner(),
            newsProvider: FakeAnnouncementProvider(script: "時刻は{hour12}時{minute}分になりました。ニュースの時間です。"),
            spotify: FakeSpotifyController(),
            clock: FakeClock(now: now),
            timeZone: tokyo
        )
        try await engine.run(plan: plan(2), corners: corners, djs: djs)
        #expect(sequencer.runs[0].announcement == "こんにちは。6月12日、午後3時になりました。")
        #expect(sequencer.runs[1].announcement == "時刻は3時7分になりました。ニュースの時間です。")
    }
}

// MARK: - S13: ED で終了 + ローリング準備

/// prepare は即時完了し、run はトークが次のトークの準備完了を待ってから進む CornerRunning。
/// 「直後のトークが準備完了済み」の状態を決定論的に作る（ED 判定テスト用）。
private final class SynchronizingRunner: CornerRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _preparedCount = 0
    private var _ranCornerIds: [String] = []
    var ranCornerIds: [String] { lock.withLock { _ranCornerIds } }
    var prepareCallCount: Int { lock.withLock { _preparedCount } }

    func prepare(corner: CornerTemplate, djs: [DjProfile]) async throws -> PreparedCorner {
        lock.withLock { _preparedCount += 1 }
        return PreparedCorner(
            corner: corner,
            song: TrackInfo(uri: "spotify:track:P", title: "T", artist: "A"),
            script: DialogueScript(lines: [])
        )
    }

    func run(prepared: PreparedCorner, djs: [DjProfile]) async throws {
        // 次のトークの準備完了（少なくとも 2 件目）を待ってから終わる（テストの決定論性のため）。
        // 最後の小さな待ちは、エンジン側の完了記録（markCornerPrepared）が走る猶予。
        for _ in 0..<200 where prepareCallCount < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        lock.withLock { _ranCornerIds.append(prepared.corner.id) }
    }
}

@Suite("BroadcastEngine: ED で終了（s13 §4）")
struct BroadcastEngineEndingTests {
    private func makeEngine(
        runner: any CornerRunning,
        sequencer: SpyThemeSequencer,
        recorder: EventRecorder,
        control: BroadcastControl,
        endAt index: Int
    ) -> BroadcastEngine {
        BroadcastEngine(
            themes: themes,
            themeSequencer: sequencer,
            cornerRunner: runner,
            newsProvider: FakeAnnouncementProvider(script: "ニュース原稿"),
            spotify: FakeSpotifyController(),
            clock: FakeClock(),
            onEvent: { event in
                recorder.append(event)
                if event == .segmentStarted(index: index, kind: .talk) {
                    control.requestEnding()
                }
            }
        )
    }

    @Test("①直後のトークが準備完了済みなら、それを流してから ED（お便り・ニュースは飛ばす）")
    func playsPreparedNextTalkThenEnding() async throws {
        let runner = SynchronizingRunner()
        let sequencer = SpyThemeSequencer()
        let recorder = EventRecorder()
        let control = BroadcastControl()
        // t1（index 2）の最中に ED 要求 → t2（index 3、準備完了済み）まで流して ED。
        let engine = makeEngine(
            runner: runner, sequencer: sequencer, recorder: recorder, control: control, endAt: 2)
        try await engine.run(plan: plan(10), corners: corners, djs: djs, control: control)

        #expect(runner.ranCornerIds == ["free_talk", "free_talk"])   // t1 + 準備済みの t2。letter は飛ばす
        #expect(sequencer.runs.map(\.trackUri) == ["spotify:track:OP", "spotify:track:ED"])   // news なし
        #expect(recorder.events.contains(.endingRequested))
        #expect(recorder.events.last == .broadcastFinished)
    }

    @Test("②直後がお便り（トーク以外）なら準備済みでも飛ばして即 ED")
    func skipsLetterAndGoesStraightToEnding() async throws {
        let runner = SynchronizingRunner()
        let sequencer = SpyThemeSequencer()
        let recorder = EventRecorder()
        let control = BroadcastControl()
        // t2（index 3）の最中に ED 要求 → 直後はお便り（index 4）→ 即 ED。
        let engine = makeEngine(
            runner: runner, sequencer: sequencer, recorder: recorder, control: control, endAt: 3)
        try await engine.run(plan: plan(10), corners: corners, djs: djs, control: control)

        #expect(runner.ranCornerIds == ["free_talk", "free_talk"])   // t1, t2 のみ（letter は実行しない）
        #expect(sequencer.runs.map(\.trackUri) == ["spotify:track:OP", "spotify:track:ED"])
        #expect(recorder.events.last == .broadcastFinished)
    }

    @Test("③直後のトークが未準備なら待たずに即 ED + 残りの準備はキャンセル")
    func unpreparedNextTalkGoesStraightToEnding() async throws {
        // prepare に実時間がかかる runner（FakeClock の song 再生は即時なので、
        // song（index 1）中の ED 要求時点でトーク（index 2）の準備は未完了）。
        final class SlowPrepareRunner: CornerRunning, @unchecked Sendable {
            private let lock = NSLock()
            private var _ranCornerIds: [String] = []
            private var _sawCancellation = false
            var ranCornerIds: [String] { lock.withLock { _ranCornerIds } }
            var sawCancellation: Bool { lock.withLock { _sawCancellation } }
            func prepare(corner: CornerTemplate, djs: [DjProfile]) async throws -> PreparedCorner {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    lock.withLock { _sawCancellation = true }
                    throw error
                }
                return PreparedCorner(
                    corner: corner, song: TrackInfo(uri: "x", title: "", artist: ""),
                    script: DialogueScript(lines: []))
            }
            func run(prepared: PreparedCorner, djs: [DjProfile]) async throws {
                lock.withLock { _ranCornerIds.append(prepared.corner.id) }
            }
        }
        let runner = SlowPrepareRunner()
        let sequencer = SpyThemeSequencer()
        let recorder = EventRecorder()
        let control = BroadcastControl()
        let engine = BroadcastEngine(
            themes: themes,
            themeSequencer: sequencer,
            cornerRunner: runner,
            newsProvider: FakeAnnouncementProvider(script: "x"),
            spotify: FakeSpotifyController(),
            clock: FakeClock(),
            onEvent: { event in
                recorder.append(event)
                if event == .segmentStarted(index: 1, kind: .song) {
                    control.requestEnding()
                }
            }
        )
        try await engine.run(plan: plan(10), corners: corners, djs: djs, control: control)

        #expect(runner.ranCornerIds.isEmpty)   // 未準備のトークは待たない
        #expect(sequencer.runs.map(\.trackUri) == ["spotify:track:OP", "spotify:track:ED"])
        // 残りの準備はキャンセルされる（非同期完了を待つ）。
        for _ in 0..<100 {
            if runner.sawCancellation { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(runner.sawCancellation)
    }

    @Test("エンドレス番組も ED 要求で終了する（plan に ED がないため合成）")
    func endlessProgramEndsOnRequest() async throws {
        let runner = SynchronizingRunner()
        let sequencer = SpyThemeSequencer()
        let recorder = EventRecorder()
        let control = BroadcastControl()
        let engine = makeEngine(
            runner: runner, sequencer: sequencer, recorder: recorder, control: control, endAt: 3)
        let endless = ProgramPlan(blueprint: blueprint(), length: .endless)
        try await engine.run(plan: endless, corners: corners, djs: djs, control: control)

        #expect(sequencer.runs.last?.trackUri == "spotify:track:ED")
        #expect(recorder.events.last == .broadcastFinished)
    }

    @Test("ローリング準備: ED で早終了した長い番組では、窓の外の準備は起動されない（全先行しない）")
    func rollingWindowDoesNotPrepareEverythingUpfront() async throws {
        let runner = SynchronizingRunner()
        let sequencer = SpyThemeSequencer()
        let recorder = EventRecorder()
        let control = BroadcastControl()
        let engine = makeEngine(
            runner: runner, sequencer: sequencer, recorder: recorder, control: control, endAt: 2)
        // N=10 = トーク 10 + お便り 5（コーナー 15 本）。t1 中に ED → 窓（先 2 つ）の分しか準備されない。
        try await engine.run(plan: plan(10), corners: corners, djs: djs, control: control)
        // prepare が呼ばれたのは t1(2), t2(3), letter(4) の最大 3 件（全 15 件を先行しない）。
        #expect(runner.prepareCallCount <= 3)
        #expect(recorder.events.last == .broadcastFinished)
    }
}
