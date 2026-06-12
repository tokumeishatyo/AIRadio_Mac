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
            func run(corner: CornerTemplate, djs: [DjProfile]) async throws {
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
