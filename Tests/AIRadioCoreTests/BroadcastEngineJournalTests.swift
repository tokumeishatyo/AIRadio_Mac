import Foundation
import Testing
import AIRadioCore
import AIRadioTestSupport

private let djs = [
    DjProfile(id: "zundamon", name: "ずんだもん", speakerId: 3, persona: ""),
    DjProfile(id: "metan", name: "四国めたん", speakerId: 2, persona: ""),
    DjProfile(id: "tsumugi", name: "春日部つむぎ", speakerId: 8, persona: ""),
    DjProfile(id: "ryusei", name: "青山龍星", speakerId: 13, persona: ""),
]
private let guests = [DjProfile(id: "sora", name: "九州そら", speakerId: 16, persona: "")]

private func corner(_ id: String, _ format: CornerFormat = .freeTalk) -> CornerTemplate {
    CornerTemplate(id: id, title: id, theme: "テーマ", format: format,
                   djIds: ["zundamon", "metan"], fallbackTrackUri: "spotify:track:F")
}
private let corners = [corner("free_talk"), corner("letter", .letter), corner("guest", .guest)]

private func theme(_ uri: String) -> ThemeConfig {
    ThemeConfig(tagline: nil, trackUri: uri, introSeconds: 5, volume: 85, duckedVolume: 35, outroSeconds: 10)
}
private func themed(_ uri: String) -> ThemedSegment {
    ThemedSegment(staging: theme(uri), byDj: [
        "zundamon": DjSpiel(announcement: "x"), "metan": DjSpiel(announcement: "x"), "tsumugi": DjSpiel(announcement: "x"),
    ])
}
private let themes = BroadcastThemes(
    opening: themed("spotify:track:OP"), news: theme("spotify:track:NEWS"), ending: themed("spotify:track:ED"))

private func blueprint() -> ProgramBlueprint {
    ProgramBlueprint(
        title: "テスト番組", anchorDjId: "zundamon",
        song: SongSegmentSpec(fallbackTrackUri: "spotify:track:SONG", playSeconds: 45),
        talkCornerId: "free_talk", letterCornerId: "letter",
        guestCornerId: "guest", artistFeatureCornerId: nil)
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _e: [BroadcastEvent] = []
    var events: [BroadcastEvent] { lock.withLock { _e } }
    func append(_ e: BroadcastEvent) { lock.withLock { _e.append(e) } }
}

private func makeEngine(
    cornerRunner: FakeCornerRunner,
    store: any JournalStore,
    summaryResponse: String,
    clock: any Clock,
    recorder: EventRecorder
) -> BroadcastEngine {
    BroadcastEngine(
        themes: themes, themeSequencer: SpyThemeSequencer(), cornerRunner: cornerRunner,
        newsProvider: FakeAnnouncementProvider(script: "ニュース"),
        spotify: FakeSpotifyController(), clock: clock,
        journalStore: store,
        journalSummarizer: JournalSummarizer(llm: ScriptedLLM(responses: [summaryResponse])),
        onEvent: { recorder.append($0) })
}

@Suite("BroadcastEngine: S18（ステーション・ジャーナル）")
struct BroadcastEngineJournalTests {
    @Test("正常終了でゲストの回はハイライトが保存される（1 回）")
    func savesOnNormalEndWithGuest() async throws {
        let store = InMemoryJournalStore()
        let recorder = EventRecorder()
        let engine = makeEngine(
            cornerRunner: FakeCornerRunner(), store: store,
            summaryResponse: "ゲストに九州そらさんを迎えました。", clock: FakeClock(), recorder: recorder)
        try await engine.run(plan: ProgramPlan(blueprint: blueprint(), length: .corners(2)),
                             corners: corners, djs: djs, guests: guests)
        #expect(recorder.events.last == .broadcastFinished)
        #expect(store.saveCount == 1)
        #expect(store.journal.entries.last?.highlight == "ゲストに九州そらさんを迎えました。")
    }

    @Test("当週の振り返りが冒頭コーナーの context.journalContext に渡る")
    func injectsJournalIntoOpening() async throws {
        let clock = FakeClock()
        let weekKey = StationJournal.weekKey(now: clock.now, timeZone: .current)
        let store = InMemoryJournalStore(StationJournal(
            weekKey: weekKey, entries: [JournalEntry(date: "1970-01-01", highlight: "米津玄師さんを特集しました。")]))
        let runner = FakeCornerRunner()
        let recorder = EventRecorder()
        let engine = makeEngine(
            cornerRunner: runner, store: store, summaryResponse: "x", clock: clock, recorder: recorder)
        try await engine.run(plan: ProgramPlan(blueprint: blueprint(), length: .corners(2)),
                             corners: corners, djs: djs, guests: guests)
        // 冒頭コーナー（greeting 付き）の context に当週の振り返りが入る。
        let opening = runner.contexts.first { $0.greeting != nil }
        #expect(opening?.journalContext?.contains("米津玄師") == true)
        // 途中コーナーには振り返りを入れない。
        let later = runner.contexts.filter { $0.greeting == nil }
        #expect(later.allSatisfy { ($0.journalContext ?? "").isEmpty })
    }

    @Test("キャンセルされた回は保存しない")
    func noSaveOnCancel() async {
        let store = InMemoryJournalStore()
        let recorder = EventRecorder()
        let engine = makeEngine(
            cornerRunner: FakeCornerRunner(errors: ["free_talk": CancellationError()]),
            store: store, summaryResponse: "x", clock: FakeClock(), recorder: recorder)
        _ = try? await engine.run(plan: ProgramPlan(blueprint: blueprint(), length: .corners(2)),
                                  corners: corners, djs: djs, guests: guests)
        #expect(!recorder.events.contains(.broadcastFinished))
        #expect(store.saveCount == 0)
    }
}
