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
private let corners = [
    corner("free_talk"), corner("letter", .letter), corner("guest", .guest),
    corner("artist_feature", .artistFeature),
]

private func theme(_ uri: String) -> ThemeConfig {
    ThemeConfig(tagline: nil, trackUri: uri, introSeconds: 5, volume: 85, duckedVolume: 35, outroSeconds: 10)
}
private func themed(_ uri: String) -> ThemedSegment {
    ThemedSegment(staging: theme(uri), byDj: [
        "zundamon": DjSpiel(announcement: "x"), "metan": DjSpiel(announcement: "x"),
        "tsumugi": DjSpiel(announcement: "x"),
    ])
}
private let themes = BroadcastThemes(
    opening: themed("spotify:track:OP"), news: theme("spotify:track:NEWS"), ending: themed("spotify:track:ED"))

private func blueprint(
    guestCornerId: String? = "guest", artistFeatureCornerId: String? = "artist_feature"
) -> ProgramBlueprint {
    ProgramBlueprint(
        title: "テスト番組", anchorDjId: "zundamon",
        song: SongSegmentSpec(fallbackTrackUri: "spotify:track:SONG", playSeconds: 45),
        talkCornerId: "free_talk", letterCornerId: "letter",
        guestCornerId: guestCornerId, artistFeatureCornerId: artistFeatureCornerId)
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [BroadcastEvent] = []
    var events: [BroadcastEvent] { lock.withLock { _events } }
    func append(_ e: BroadcastEvent) { lock.withLock { _events.append(e) } }
}

private func makeEngine(
    artistRunner: FakeArtistFeatureRunner,
    recorder: EventRecorder,
    randomIndex: @escaping @Sendable (Int) -> Int = { _ in 0 }
) -> BroadcastEngine {
    BroadcastEngine(
        themes: themes, themeSequencer: SpyThemeSequencer(),
        cornerRunner: FakeCornerRunner(),
        artistFeatureRunner: artistRunner,
        newsProvider: FakeAnnouncementProvider(script: "ニュース"),
        spotify: FakeSpotifyController(), clock: FakeClock(),
        randomIndex: randomIndex, onEvent: { recorder.append($0) })
}

@Suite("BroadcastEngine: S15（アーティスト特集）")
struct BroadcastEngineArtistFeatureTests {
    @Test("N=2: 選定アーティストが特集ランナーに渡り、1 回 run される")
    func selectsAndRuns() async throws {
        let artistRunner = FakeArtistFeatureRunner()
        let recorder = EventRecorder()
        let engine = makeEngine(artistRunner: artistRunner, recorder: recorder)
        try await engine.run(
            plan: ProgramPlan(blueprint: blueprint(), length: .corners(2)),
            corners: corners, djs: djs, guests: guests,
            artists: [ArtistProfile(id: "a", name: "米津玄師"), ArtistProfile(id: "b", name: "あいみょん")])

        #expect(artistRunner.preparedArtistNames == ["米津玄師"])   // randomIndex {0}
        #expect(artistRunner.ranSkipped == [false])
        #expect(recorder.events.last == .broadcastFinished)
    }

    @Test("プール空: artist=nil で準備＝スキップ、放送は継続する")
    func emptyPoolSkipsButContinues() async throws {
        let artistRunner = FakeArtistFeatureRunner()
        let recorder = EventRecorder()
        let engine = makeEngine(artistRunner: artistRunner, recorder: recorder)
        try await engine.run(
            plan: ProgramPlan(blueprint: blueprint(), length: .corners(2)),
            corners: corners, djs: djs, guests: guests, artists: [])

        #expect(artistRunner.preparedArtistNames == [nil])
        #expect(artistRunner.ranSkipped == [true])
        #expect(recorder.events.last == .broadcastFinished)
    }

    @Test("fail-fast: artist_feature.corner_id のコーナーが無い")
    func failsFastWhenCornerMissing() async throws {
        let engine = makeEngine(artistRunner: FakeArtistFeatureRunner(), recorder: EventRecorder())
        let cornersWithoutFeature = [corner("free_talk"), corner("letter", .letter), corner("guest", .guest)]
        await #expect(throws: ConfigError.self) {
            try await engine.run(
                plan: ProgramPlan(blueprint: blueprint(), length: .corners(2)),
                corners: cornersWithoutFeature, djs: djs, guests: guests,
                artists: [ArtistProfile(id: "a", name: "x")])
        }
    }

    @Test("fail-fast: artist_feature.corner_id が guest と重複")
    func failsFastWhenCornerCollides() async throws {
        let engine = makeEngine(artistRunner: FakeArtistFeatureRunner(), recorder: EventRecorder())
        await #expect(throws: ConfigError.self) {
            try await engine.run(
                plan: ProgramPlan(blueprint: blueprint(artistFeatureCornerId: "guest"), length: .corners(2)),
                corners: corners, djs: djs, guests: guests,
                artists: [ArtistProfile(id: "a", name: "x")])
        }
    }
}
