import Testing
import Foundation
import AIRadioCore
import AIRadioTestSupport

private struct ThrowingAudioPlayer: AudioPlayer {
    func play(_ wav: Data) async throws { throw AudioError.playbackFailed }
}

struct ThemeSequencerTests {
    private func makeTheme(tagline: String?) -> ThemeConfig {
        ThemeConfig(
            tagline: tagline,
            trackUri: "spotify:track:bgm",
            introSeconds: 5,
            volume: 80,
            duckedVolume: 30,
            outroSeconds: 3
        )
    }

    @Test func ordersEventsWithTagline() async throws {
        let spotify = FakeSpotifyController(durationSeconds: 60)
        let audio = SpyAudioPlayer()
        let sequencer = ThemeSequencer(tts: InMemoryTTS(), audio: audio, spotify: spotify, clock: FakeClock())

        try await sequencer.run(theme: makeTheme(tagline: "タグライン"), announcement: "本文", speakerId: 3)

        #expect(spotify.events == [
            .play("spotify:track:bgm"),
            .setVolume(80),    // イントロ フル音量
            .setVolume(30),    // ダッキング
            .seek(57),         // 曲の残り 3 秒へ（60 - 3）
            .setVolume(80),    // アンダック
            .pause,            // 完全静寂
        ])
        #expect(audio.played.count == 2)  // tagline + announcement
    }

    @Test func skipsTaglineAudioWhenNil() async throws {
        let spotify = FakeSpotifyController(durationSeconds: 60)
        let audio = SpyAudioPlayer()
        let sequencer = ThemeSequencer(tts: InMemoryTTS(), audio: audio, spotify: spotify, clock: FakeClock())

        try await sequencer.run(theme: makeTheme(tagline: nil), announcement: "本文", speakerId: 3)

        #expect(audio.played.count == 1)  // announcement のみ
        #expect(spotify.events.first == .play("spotify:track:bgm"))
        #expect(spotify.events.last == .pause)
    }

    @Test func skipsSeekWhenDurationUnknownOrShorterThanOutro() async throws {
        let spotify = FakeSpotifyController(durationSeconds: 0)  // 取得不可
        let audio = SpyAudioPlayer()
        let sequencer = ThemeSequencer(tts: InMemoryTTS(), audio: audio, spotify: spotify, clock: FakeClock())

        try await sequencer.run(theme: makeTheme(tagline: nil), announcement: "本文", speakerId: 3)

        let hasSeek = spotify.events.contains { if case .seek = $0 { return true }; return false }
        #expect(hasSeek == false)  // 曲長不明ならシークしない
        #expect(spotify.events.last == .pause)
    }

    @Test func pausesEvenWhenPlaybackFails() async {
        let spotify = FakeSpotifyController()
        let sequencer = ThemeSequencer(tts: InMemoryTTS(), audio: ThrowingAudioPlayer(), spotify: spotify, clock: FakeClock())

        await #expect(throws: AudioError.playbackFailed) {
            try await sequencer.run(theme: makeTheme(tagline: nil), announcement: "本文", speakerId: 3)
        }
        #expect(spotify.events.contains(.pause))  // §3-1 完全静寂を保証
        #expect(spotify.events.last == .setVolume(80))  // ダッキング中の停止でも音量をフルへ復元
    }
}
