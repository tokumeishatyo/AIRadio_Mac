import Testing
import Foundation
import AIRadioCore
import AIRadioTestSupport

struct FakesTests {
    @Test func echoLLMEchoesPrompt() async throws {
        let llm: LLMBackend = EchoLLM()
        let result = try await llm.generate(LLMRequest(prompt: "こんにちは"))
        #expect(result == "echo: こんにちは")
    }

    @Test func inMemoryTTSReturnsNonEmptyData() async throws {
        let tts: TTSBackend = InMemoryTTS()
        let data = try await tts.synthesize(text: "テスト", speakerId: 3)
        #expect(!data.isEmpty)
    }

    @Test func spyAudioPlayerRecordsPlays() async throws {
        let player = SpyAudioPlayer()
        try await player.play(Data([0x01]))
        try await player.play(Data([0x02]))
        #expect(player.played.count == 2)
    }

    @Test func fakeSpotifyControllerRecordsCallOrder() async throws {
        let spotify = FakeSpotifyController()
        try await spotify.play(uri: "spotify:track:abc")
        try await spotify.setVolume(90)
        try await spotify.seek(toSeconds: 30)
        try await spotify.pause()
        #expect(spotify.events == [.play("spotify:track:abc"), .setVolume(90), .seek(30), .pause])
    }

    @Test func fakeTrackSearcherRecordsQueriesAndReturnsResults() async throws {
        let track = TrackInfo(uri: "spotify:track:1", title: "曲", artist: "歌手")
        let searcher = FakeTrackSearcher(results: [track])
        let results = try await searcher.search(query: "歌手 曲", limit: 5)
        #expect(results == [track])
        #expect(searcher.queries == ["歌手 曲"])
        #expect(try await searcher.isPlayable("spotify:track:1") == true)
        #expect(try await searcher.isPlayable("spotify:track:unknown") == false)
    }

    @Test func fakeClockSleepIsInstant() async throws {
        let clock: Clock = FakeClock()
        try await clock.sleep(seconds: 9999)  // 即時に返るはず
        #expect(clock.now == Date(timeIntervalSince1970: 0))
    }

    @Test func fakeResearchSourceReturnsPayload() async throws {
        let source: ResearchSource = FakeResearchSource(payload: "本日のニュース")
        #expect(try await source.fetch() == "本日のニュース")
    }
}
