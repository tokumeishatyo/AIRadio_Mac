import Foundation
import Testing
import AIRadioCore
import AIRadioTestSupport

private let djs = [
    DjProfile(id: "zundamon", name: "ずんだもん", speakerId: 3, persona: ""),
    DjProfile(id: "metan", name: "四国めたん", speakerId: 2, persona: ""),
]

private func featureCorner(playSeconds: Int = 1) -> CornerTemplate {
    CornerTemplate(
        id: "artist_feature", title: "アーティスト特集", theme: "x",
        format: .artistFeature, djIds: ["zundamon", "metan"],
        fallbackTrackUri: "spotify:track:F", volume: 100, playSeconds: playSeconds,
        leadIn: "{ampm}{hour}時です。本日は{artist}さんを特集します。",
        artistFeatureParams: ArtistFeatureParams(outroLine: "以上、アーティスト特集でした。")
    )
}

private func tracks(_ n: Int) -> [TrackInfo] {
    (1...n).map { TrackInfo(uri: "spotify:track:T\($0)", title: "曲\($0)", artist: "米津玄師") }
}

/// パースできる台本応答を n 個（メイン＋サブの 2 行）。
private func validResponses(_ n: Int) -> [String] {
    Array(repeating: "ずんだもん: テストのセリフ\n四国めたん: 受けのセリフ", count: n)
}

private final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [T] = []
    func add(_ item: T) { lock.withLock { _items.append(item) } }
    var items: [T] { lock.withLock { _items } }
}

private func playCount(_ events: [SpotifyEvent]) -> Int {
    events.filter { if case .play = $0 { return true } else { return false } }.count
}

@Suite("ArtistFeatureEngine（アーティスト特集、s15）")
struct ArtistFeatureEngineTests {
    @Test("グループ分割: 7→3+3+1, 6→3+3, 5→3+2, 4→3+1, 3→3")
    func splitGroups() {
        #expect(ArtistFeatureEngine.splitGroups(tracks(7)).map(\.count) == [3, 3, 1])
        #expect(ArtistFeatureEngine.splitGroups(tracks(6)).map(\.count) == [3, 3])
        #expect(ArtistFeatureEngine.splitGroups(tracks(5)).map(\.count) == [3, 2])
        #expect(ArtistFeatureEngine.splitGroups(tracks(4)).map(\.count) == [3, 1])
        #expect(ArtistFeatureEngine.splitGroups(tracks(3)).map(\.count) == [3])
    }

    @Test("重複除外: 同一 URI と正規化タイトル（別バージョン）を除く")
    func deduplicate() {
        let input = [
            TrackInfo(uri: "u1", title: "曲A", artist: "x"),
            TrackInfo(uri: "u1", title: "曲A2", artist: "x"),               // 同 URI → 除外
            TrackInfo(uri: "u2", title: "曲A (Remaster)", artist: "x"),     // 正規化で 曲A と同じ → 除外
            TrackInfo(uri: "u3", title: "曲B", artist: "x"),
        ]
        #expect(ArtistFeatureEngine.deduplicate(input).map(\.uri) == ["u1", "u3"])
    }

    @Test("準備（K=7）: 3+3+1 のグループ・パート別台本・固定締め・{artist} 置換")
    func prepareFull() async throws {
        let engine = ArtistFeatureEngine(
            llm: ScriptedLLM(responses: validResponses(6)),   // 導入1 + グループ紹介3 + 感想2
            tts: InMemoryTTS(), audio: SpyAudioPlayer(),
            catalog: FakeArtistCatalog(byArtist: ["米津玄師": tracks(7)]),
            spotify: FakeSpotifyController(), clock: FakeClock())
        let prepared = try await engine.prepare(
            corner: featureCorner(), artist: ArtistProfile(id: "a", name: "米津玄師"),
            djs: djs, castDjIds: ["zundamon", "metan"], leadIn: featureCorner().leadIn)

        #expect(prepared.skipped == false)
        #expect(prepared.groups.map(\.count) == [3, 3, 1])
        #expect(prepared.groupIntroScripts.count == 3)
        #expect(prepared.commentScripts.count == 2)   // 最後のグループの後は締め＝感想なし
        #expect(prepared.outroLine.text == "以上、アーティスト特集でした。")
        #expect(prepared.leadIn?.contains("米津玄師") == true)
        #expect(prepared.introAudio.count == prepared.introScript.lines.count)
    }

    @Test("準備: プール空（artist=nil）はスキップ準備物（E-ART-EMPTY-POOL）")
    func prepareEmptyPool() async throws {
        let engine = ArtistFeatureEngine(
            llm: ScriptedLLM(responses: []), tts: InMemoryTTS(), audio: SpyAudioPlayer(),
            catalog: FakeArtistCatalog(), spotify: FakeSpotifyController(), clock: FakeClock())
        let prepared = try await engine.prepare(
            corner: featureCorner(), artist: nil, djs: djs, castDjIds: ["zundamon", "metan"], leadIn: nil)
        #expect(prepared.skipped)
        #expect(prepared.skipReason?.contains("EMPTY-POOL") == true)
    }

    @Test("準備: 再生可能曲が 3 曲未満はスキップ（E-ART-INSUFFICIENT-TRACKS）")
    func prepareInsufficient() async throws {
        let engine = ArtistFeatureEngine(
            llm: ScriptedLLM(responses: []), tts: InMemoryTTS(), audio: SpyAudioPlayer(),
            catalog: FakeArtistCatalog(byArtist: ["米津玄師": tracks(2)]),
            spotify: FakeSpotifyController(), clock: FakeClock())
        let prepared = try await engine.prepare(
            corner: featureCorner(), artist: ArtistProfile(id: "a", name: "米津玄師"),
            djs: djs, castDjIds: ["zundamon", "metan"], leadIn: nil)
        #expect(prepared.skipped)
        #expect(prepared.skipReason?.contains("INSUFFICIENT") == true)
    }

    @Test("本番（K=4）: 4 曲を連続再生（曲間 pause なし）→ 最後に 1 回 pause、締め音声が最後")
    func runPlaysContinuously() async throws {
        let audio = SpyAudioPlayer()
        let spotify = FakeSpotifyController()
        let collector = Collector<ArtistFeatureEvent>()
        let engine = ArtistFeatureEngine(
            llm: ScriptedLLM(responses: validResponses(4)),   // 導入1 + グループ紹介2 + 感想1
            tts: InMemoryTTS(), audio: audio,
            catalog: FakeArtistCatalog(byArtist: ["米津玄師": tracks(4)]),
            spotify: spotify, clock: FakeClock(), onEvent: { collector.add($0) })
        let prepared = try await engine.prepare(
            corner: featureCorner(playSeconds: 1), artist: ArtistProfile(id: "a", name: "米津玄師"),
            djs: djs, castDjIds: ["zundamon", "metan"], leadIn: featureCorner().leadIn)

        try await engine.run(prepared: prepared, djs: djs)

        #expect(playCount(spotify.events) == 4)
        // 各グループの後に pause（[3,1] の 2 グループ）＋ run 末尾の pause = 3。
        #expect(spotify.events.filter { $0 == .pause }.count == 3)
        #expect(spotify.events.last == .pause)
        // グループ1（3曲）は曲間に pause を挟まず連続: 最初の pause より前に play が 3 つ。
        let firstPause = spotify.events.firstIndex(of: .pause) ?? spotify.events.count
        let group1Plays = spotify.events.prefix(firstPause)
            .filter { if case .play = $0 { return true } else { return false } }.count
        #expect(group1Plays == 3)
        #expect(collector.items.filter { if case .songStarted = $0 { return true } else { return false } }.count == 4)
        #expect(!collector.items.contains { if case .featureSkipped = $0 { return true } else { return false } })
        #expect(audio.played.last == prepared.outroAudio)
    }

    @Test("本番: スキップ準備物は featureSkipped を出して何も再生しない")
    func runSkipped() async throws {
        let spotify = FakeSpotifyController()
        let collector = Collector<ArtistFeatureEvent>()
        let engine = ArtistFeatureEngine(
            llm: ScriptedLLM(responses: []), tts: InMemoryTTS(), audio: SpyAudioPlayer(),
            catalog: FakeArtistCatalog(), spotify: spotify, clock: FakeClock(),
            onEvent: { collector.add($0) })
        let prepared = PreparedArtistFeature.skip(
            corner: featureCorner(), castDjIds: ["zundamon", "metan"], reason: "E-ART-EMPTY-POOL-001: x")

        try await engine.run(prepared: prepared, djs: djs)

        #expect(collector.items.contains { if case .featureSkipped = $0 { return true } else { return false } })
        #expect(spotify.events.isEmpty)
    }
}
