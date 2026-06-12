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

private func theme(_ uri: String) -> ThemeConfig {
    ThemeConfig(tagline: nil, trackUri: uri, introSeconds: 5, volume: 85, duckedVolume: 35, outroSeconds: 10)
}

private let themes = BroadcastThemes(
    opening: ThemedAnnouncement(theme: theme("spotify:track:OP"), announcement: "オープニングです"),
    news: theme("spotify:track:NEWS"),
    ending: ThemedAnnouncement(theme: theme("spotify:track:ED"), announcement: "エンディングです")
)

private let program = Program(
    title: "テスト番組",
    anchorDjId: "zundamon",
    segments: [
        ProgramSegment(kind: .opening),
        ProgramSegment(kind: .talk, cornerId: "free_talk"),
        ProgramSegment(kind: .news),
        ProgramSegment(kind: .ending),
    ]
)

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
    @Test("正常系: 宣言順に実行し、最後に pause + broadcastFinished")
    func happyPathRunsInOrder() async throws {
        let fixture = Fixture()
        try await fixture.engine.run(program: program, corners: [freeTalk], djs: djs)

        // テーマ演出: OP → ニュース（実行時原稿） → ED の順、読み上げはアンカー DJ（ずんだもん=3）。
        #expect(fixture.sequencer.runs == [
            SpyThemeSequencer.Run(trackUri: "spotify:track:OP", announcement: "オープニングです", speakerId: 3),
            SpyThemeSequencer.Run(trackUri: "spotify:track:NEWS", announcement: "ニュース原稿", speakerId: 3),
            SpyThemeSequencer.Run(trackUri: "spotify:track:ED", announcement: "エンディングです", speakerId: 3),
        ])
        #expect(fixture.cornerRunner.ranCornerIds == ["free_talk"])
        #expect(fixture.spotify.events.contains(.pause))
        #expect(fixture.recorder.events == [
            .segmentStarted(index: 0, kind: .opening), .segmentFinished(index: 0, kind: .opening),
            .segmentStarted(index: 1, kind: .talk), .segmentFinished(index: 1, kind: .talk),
            .segmentStarted(index: 2, kind: .news), .segmentFinished(index: 2, kind: .news),
            .segmentStarted(index: 3, kind: .ending), .segmentFinished(index: 3, kind: .ending),
            .broadcastFinished,
        ])
    }

    @Test("セグメント失敗はスキップして放送継続（コーナースキップ）+ 最後に pause")
    func skipsFailedSegmentAndContinues() async throws {
        let fixture = Fixture(cornerErrors: ["free_talk": LLMError.emptyResponse])
        try await fixture.engine.run(program: program, corners: [freeTalk], djs: djs)

        // talk は失敗したが、news / ending は実行されて放送は最後まで進む。
        #expect(fixture.recorder.events.contains(
            .segmentFailed(index: 1, kind: .talk, code: "E-LLM-EMPTY-RESPONSE-001",
                           detail: LLMError.emptyResponse.message)))
        #expect(fixture.sequencer.runs.count == 3)
        #expect(fixture.recorder.events.last == .broadcastFinished)
        #expect(fixture.spotify.events.contains(.pause))
    }

    @Test("キャンセルは即時伝播: 後続セグメントは実行せず、必ず pause、broadcastFinished なし")
    func cancellationStopsImmediately() async {
        let fixture = Fixture(cornerErrors: ["free_talk": CancellationError()])
        await #expect(throws: CancellationError.self) {
            try await fixture.engine.run(program: program, corners: [freeTalk], djs: djs)
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
            try await engine.run(program: program, corners: [freeTalk], djs: djs)
        }
        // talk の後の news / ending には進まない（OP の 1 回のみ）。
        #expect(sequencer.runs.count == 1)
        #expect(!recorder.events.contains { event in
            if case .segmentFailed = event { return true } else { return false }
        })
        #expect(spotify.events.contains(.pause))
    }

    @Test("critical セグメントの失敗は放送中止（スキップしない、Windows 版踏襲）")
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
        let criticalProgram = Program(title: "t", anchorDjId: "zundamon", segments: [
            ProgramSegment(kind: .opening, critical: true),
            ProgramSegment(kind: .talk, cornerId: "free_talk"),
        ])
        await #expect(throws: BroadcastError.self) {
            try await engine.run(program: criticalProgram, corners: [freeTalk], djs: djs)
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
            try await engine.run(program: program, corners: [freeTalk], djs: djs)
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
        let songProgram = Program(title: "テスト番組", anchorDjId: "zundamon", segments: [
            ProgramSegment(kind: .opening),
            ProgramSegment(kind: .song, song: SongSegmentSpec(
                promptHint: "幕開けの曲", fallbackTrackUri: "spotify:track:FALLBACK", volume: 100, playSeconds: 45)),
            ProgramSegment(kind: .ending),
        ])
        try await engine.run(program: songProgram, corners: [], djs: djs)

        // OP の曲振りに確定曲が入る。
        #expect(sequencer.runs[0].announcement == "それでは聴いてください。YOASOBIで、「夜に駆ける」。")
        // song セグメント: 再生 → 音量 → pause。
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
        let songProgram = Program(title: "t", anchorDjId: "zundamon", segments: [
            ProgramSegment(kind: .opening),
            ProgramSegment(kind: .song, song: SongSegmentSpec(fallbackTrackUri: "spotify:track:FALLBACK")),
        ])
        try await engine.run(program: songProgram, corners: [], djs: djs)
        #expect(sequencer.runs[0].announcement == "本日の一曲。")
        #expect(spotify.events.contains(.play("spotify:track:FALLBACK")))
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
        let songProgram = Program(title: "t", anchorDjId: "zundamon", segments: [
            ProgramSegment(kind: .song, song: SongSegmentSpec(fallbackTrackUri: "spotify:track:F", playSeconds: 0)),
        ])
        try await engine.run(program: songProgram, corners: [], djs: djs)
        // ポーリング（0.2s × 2）の後、新曲の残り 240 - margin(5) = 235 秒で待つ（30 秒側で早切りしない）。
        #expect(clock.sleeps.contains(235))
        #expect(!clock.sleeps.contains(30))
        #expect(!clock.sleeps.contains(25))
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
        try await engine.run(
            program: Program(title: "t", anchorDjId: "zundamon", segments: [
                ProgramSegment(kind: .song, song: SongSegmentSpec(fallbackTrackUri: "spotify:track:F")),
            ]),
            corners: [], djs: djs)
        // 上限（margin+10 秒 = 0.5s × 20 ポーリング）まで粘らず、位置停滞の検知で数回のうちに抜ける。
        let endPolls = clock.sleeps.filter { $0 == 0.5 }
        #expect(endPolls.count <= 3)
    }

    @Test("talk の準備は放送開始時に先行起動され、本番は準備済み成果物で実行される")
    func talkUsesPreparedContent() async throws {
        let fixture = Fixture()
        try await fixture.engine.run(program: program, corners: [freeTalk], djs: djs)
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
            try await engine.run(
                program: Program(title: "t", anchorDjId: "zundamon",
                                 segments: [ProgramSegment(kind: .talk, cornerId: "free_talk")]),
                corners: [freeTalk], djs: djs)
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

    @Test("未定義の corner_id は fail-fast（音を出す前に設定エラー）")
    func unknownCornerIdFailsFast() async {
        let fixture = Fixture()
        let broken = Program(title: "t", anchorDjId: "zundamon",
                             segments: [ProgramSegment(kind: .talk, cornerId: "unknown")])
        await #expect(throws: ConfigError.self) {
            try await fixture.engine.run(program: broken, corners: [freeTalk], djs: djs)
        }
        #expect(fixture.sequencer.runs.isEmpty)
        #expect(fixture.recorder.events.isEmpty || !fixture.recorder.events.contains(.broadcastFinished))
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
        try await engine.run(program: program, corners: [freeTalk], djs: djs)
        #expect(sequencer.runs[0].announcement == "こんにちは。6月12日、午後3時になりました。")
        #expect(sequencer.runs[1].announcement == "時刻は3時7分になりました。ニュースの時間です。")
        #expect(sequencer.runs[2].announcement == "ED")
    }

    @Test("テーマ系セグメントの dj_id で読み上げ DJ を切り替え（ニュース=青山龍星）")
    func newsUsesSegmentDj() async throws {
        let cast = djs + [DjProfile(id: "ryusei", name: "青山龍星", speakerId: 13, persona: "")]
        let withNewsDj = Program(title: "t", anchorDjId: "zundamon", segments: [
            ProgramSegment(kind: .opening),
            ProgramSegment(kind: .news, djId: "ryusei"),
            ProgramSegment(kind: .ending),
        ])
        let fixture = Fixture()
        try await fixture.engine.run(program: withNewsDj, corners: [], djs: cast)
        #expect(fixture.sequencer.runs.map(\.speakerId) == [3, 13, 3])
    }

    @Test("未定義の dj_id は fail-fast")
    func unknownSegmentDjFailsFast() async {
        let fixture = Fixture()
        let broken = Program(title: "t", anchorDjId: "zundamon",
                             segments: [ProgramSegment(kind: .news, djId: "nobody")])
        await #expect(throws: ConfigError.self) {
            try await fixture.engine.run(program: broken, corners: [], djs: djs)
        }
        #expect(fixture.sequencer.runs.isEmpty)
    }

    @Test("未定義の anchor_dj_id は fail-fast")
    func unknownAnchorFailsFast() async {
        let fixture = Fixture()
        let broken = Program(title: "t", anchorDjId: "nobody", segments: [ProgramSegment(kind: .opening)])
        await #expect(throws: ConfigError.self) {
            try await fixture.engine.run(program: broken, corners: [freeTalk], djs: djs)
        }
        #expect(fixture.sequencer.runs.isEmpty)
    }
}
