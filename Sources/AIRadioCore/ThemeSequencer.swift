import Foundation

/// テーマ曲 + 発話のダッキング演出を行う抽象。
public protocol ThemeSequencing: Sendable {
    func run(theme: ThemeConfig, announcement: String, speakerId: Int) async throws
}

/// OP / ニュース / ED が共有する統一テーマ/BGM 演出の実装。
/// 再生はアトミック（指定 URI をそのまま再生）である前提（Web API 再生）。
public struct ThemeSequencer: ThemeSequencing {
    private let tts: any TTSBackend
    private let audio: any AudioPlayer
    private let spotify: any SpotifyController
    private let clock: any Clock

    public init(
        tts: any TTSBackend,
        audio: any AudioPlayer,
        spotify: any SpotifyController,
        clock: any Clock
    ) {
        self.tts = tts
        self.audio = audio
        self.spotify = spotify
        self.clock = clock
    }

    public func run(theme: ThemeConfig, announcement: String, speakerId: Int) async throws {
        do {
            try await sequence(theme: theme, announcement: announcement, speakerId: speakerId)
        } catch {
            // 完全静寂（§3-1）: エラー / キャンセルでも必ず BGM を止め、音量をフルに戻す。
            await spotify.pauseIgnoringCancellation(restoringVolume: theme.volume)
            throw error
        }
        try await spotify.pause()
    }

    private func sequence(theme: ThemeConfig, announcement: String, speakerId: Int) async throws {
        // tagline（BGM 前の一言、ED は nil）
        if let tagline = theme.tagline, !tagline.isEmpty {
            let taglineWav = try await tts.synthesize(text: tagline, speakerId: speakerId)
            try await audio.play(taglineWav)
        }

        // BGM イントロ（フル音量）。発話はイントロ中に先行合成する。
        try await spotify.play(uri: theme.trackUri)
        try await spotify.setVolume(theme.volume)
        async let announcementWav = tts.synthesize(text: announcement, speakerId: speakerId)
        try await clock.sleep(seconds: Double(theme.introSeconds))

        // ダッキング → 発話
        try await spotify.setVolume(theme.duckedVolume)
        let wav = try await announcementWav
        try await audio.play(wav)

        // アウトロ: 曲の「残り outroSeconds 秒」へシーク → アンダック → 曲の終わりまで再生。
        let duration = (try? await spotify.currentTrackDurationSeconds()) ?? 0
        if duration > Double(theme.outroSeconds) {
            try await spotify.seek(toSeconds: Int(duration.rounded()) - theme.outroSeconds)
        }
        try await spotify.setVolume(theme.volume)  // アンダック（フル音量）
        try await clock.sleep(seconds: Double(theme.outroSeconds))
    }
}
