import Foundation
import Testing
import AIRadioCore
import AIRadioTestSupport

private let djs = [
    DjProfile(id: "zundamon", name: "ずんだもん", speakerId: 3, persona: "なのだ口調"),
    DjProfile(id: "metan", name: "四国めたん", speakerId: 2, persona: "上品な口調"),
]

private func corner(playSeconds: Int = 60) -> CornerTemplate {
    CornerTemplate(
        id: "free_talk",
        title: "フリートーク",
        theme: "最近気になっていること",
        djIds: ["zundamon", "metan"],
        fallbackTrackUri: "spotify:track:FALLBACK",
        volume: 85,
        playSeconds: playSeconds
    )
}

private let candidatesResponse = "夜に駆ける - YOASOBI"
private let scriptResponse = """
ずんだもん: こんにちはなのだ。
四国めたん: ごきげんよう。
ずんだもん: 今日はこのテーマなのだ。
四国めたん: 最後は夜に駆けるですわ。
"""

/// sleep の引数を記録する Clock。
private final class RecordingClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [Double] = []
    let now = Date(timeIntervalSince1970: 0)
    var sleeps: [Double] { lock.withLock { _sleeps } }
    func sleep(seconds: Double) async throws {
        lock.withLock { _sleeps.append(seconds) }
    }
}

private struct Fixture {
    let llm: ScriptedLLM
    let tts = InMemoryTTS()
    let audio = SpyAudioPlayer()
    let searcher: FakeTrackSearcher
    let spotify: FakeSpotifyController
    let clock = RecordingClock()
    let engine: CornerEngine

    init(
        responses: [String] = [candidatesResponse, scriptResponse],
        searchResults: [TrackInfo] = [TrackInfo(uri: "spotify:track:OK", title: "夜に駆ける", artist: "YOASOBI")],
        durationSeconds: Double = 240
    ) {
        llm = ScriptedLLM(responses: responses)
        searcher = FakeTrackSearcher(results: searchResults)
        spotify = FakeSpotifyController(durationSeconds: durationSeconds)
        engine = CornerEngine(
            llm: llm, tts: tts, audio: audio, searcher: searcher,
            spotify: spotify, clock: clock
        )
    }
}

@Suite("CornerEngine")
struct CornerEngineTests {
    @Test("正常系: 台本 4 行を発話 → 確定曲を再生 → play_seconds 待って pause")
    func happyPath() async throws {
        let fixture = Fixture()
        try await fixture.engine.run(corner: corner(playSeconds: 60), djs: djs)

        // 発話: 4 行が DJ の speaker id で合成・再生される（InMemoryTTS は "speakerId:text"）。
        #expect(fixture.audio.played.count == 4)
        #expect(fixture.audio.played[0] == Data("3:こんにちはなのだ。".utf8))
        #expect(fixture.audio.played[1] == Data("2:ごきげんよう。".utf8))

        // 一曲: プレフライト済みの曲を再生し、音量設定 → 60 秒 → pause（完全静寂）。
        #expect(fixture.spotify.events == [
            .play("spotify:track:OK"),
            .setVolume(85),
            .pause,
        ])
        #expect(fixture.clock.sleeps == [60])
    }

    @Test("play_seconds=0 なら曲の長さぶん待つ（フル再生）")
    func fullPlaybackUsesTrackDuration() async throws {
        let fixture = Fixture(durationSeconds: 240)
        try await fixture.engine.run(corner: corner(playSeconds: 0), djs: djs)
        #expect(fixture.clock.sleeps == [240])
    }

    @Test("台本生成失敗は準備段階（無音）のエラー: 音は出ておらず pause 不要")
    func scriptFailureHappensSilentlyInPreparation() async {
        // 2 回目の LLM 応答（台本）が形式不正 → パース失敗（prepare 内）。
        let fixture = Fixture(responses: [candidatesResponse, "形式不正の応答"])
        await #expect(throws: LLMError.self) {
            try await fixture.engine.run(corner: corner(), djs: djs)
        }
        #expect(fixture.audio.played.isEmpty)
        #expect(fixture.spotify.events.isEmpty)  // prepare は音を出さない
    }

    @Test("prepare は LLM 成果物を返し、run(prepared:) は LLM を呼ばずに本番だけ行う")
    func prepareAndRunAreSeparated() async throws {
        let fixture = Fixture()
        let prepared = try await fixture.engine.prepare(corner: corner(playSeconds: 60), djs: djs)
        #expect(prepared.song.uri == "spotify:track:OK")
        #expect(prepared.script.lines.count == 4)
        #expect(fixture.llm.requests.count == 2)       // 選曲 + 台本
        #expect(fixture.audio.played.isEmpty)          // 準備では音を出さない

        try await fixture.engine.run(prepared: prepared, djs: djs)
        #expect(fixture.llm.requests.count == 2)       // 本番で LLM は呼ばれない
        #expect(fixture.audio.played.count == 4)
        #expect(fixture.spotify.events == [.play("spotify:track:OK"), .setVolume(85), .pause])
    }

    @Test("未定義の DJ id は設定エラー")
    func unknownDjIdThrows() async {
        let fixture = Fixture()
        var broken = corner()
        broken.djIds = ["zundamon", "unknown"]
        await #expect(throws: ConfigError.self) {
            try await fixture.engine.run(corner: broken, djs: djs)
        }
    }

    @Test("プレフライトが台本生成より先（選曲 → 台本の順で LLM が呼ばれる）")
    func preflightBeforeScript() async throws {
        let fixture = Fixture()
        try await fixture.engine.run(corner: corner(), djs: djs)
        #expect(fixture.llm.requests.count == 2)
        #expect(fixture.llm.requests[0].prompt.contains("候補"))
        #expect(fixture.llm.requests[1].prompt.contains("夜に駆ける"))
    }

    @Test("イベント通知の順序（選曲 → 台本 → 行 → 曲）")
    func emitsEventsInOrder() async throws {
        let recorder = EventRecorder()
        let fixture = Fixture()
        let engine = CornerEngine(
            llm: fixture.llm, tts: fixture.tts, audio: fixture.audio,
            searcher: fixture.searcher, spotify: fixture.spotify, clock: fixture.clock,
            onEvent: { recorder.append($0) }
        )
        try await engine.run(corner: corner(), djs: djs)
        let events = recorder.events
        #expect(events.count == 7)  // songPicked + scriptReady + 4 行 + songStarted
        #expect(events.first == .songPicked(TrackInfo(uri: "spotify:track:OK", title: "夜に駆ける", artist: "YOASOBI")))
        #expect(events[1] == .scriptReady(lineCount: 4, totalCharacters: 40))
        #expect(events.last == .songStarted(TrackInfo(uri: "spotify:track:OK", title: "夜に駆ける", artist: "YOASOBI")))
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [CornerEvent] = []
    var events: [CornerEvent] { lock.withLock { _events } }
    func append(_ event: CornerEvent) { lock.withLock { _events.append(event) } }
}
