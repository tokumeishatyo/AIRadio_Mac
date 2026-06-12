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

        // BGM イントロ（フル音量）。発話は文単位のチャンクに分け、最初のチャンクをイントロ中に先行合成。
        // 長文（LLM ニュース原稿等）を一括合成するとダッキング後に合成待ちのデッドエアが出るため（S11 fix）。
        let chunks = Self.chunkAnnouncement(announcement)
        try await spotify.play(uri: theme.trackUri)
        try await spotify.setVolume(theme.volume)

        var pending: Data?
        if let first = chunks.first {
            async let firstWav = tts.synthesize(text: first, speakerId: speakerId)
            try await clock.sleep(seconds: Double(theme.introSeconds))
            try await spotify.setVolume(theme.duckedVolume)
            pending = try await firstWav
        } else {
            try await clock.sleep(seconds: Double(theme.introSeconds))
            try await spotify.setVolume(theme.duckedVolume)
        }

        // 発話: 次のチャンクは現在チャンクの再生中に先行合成する。
        var index = 0
        while let current = pending {
            let nextIndex = index + 1
            if nextIndex < chunks.count {
                async let prefetch = tts.synthesize(text: chunks[nextIndex], speakerId: speakerId)
                try await audio.play(current)
                pending = try await prefetch
            } else {
                try await audio.play(current)
                pending = nil
            }
            index = nextIndex
        }

        // アウトロ: 曲の「残り outroSeconds 秒」へシーク → アンダック → 曲の終わりまで再生。
        let duration = (try? await spotify.currentTrackDurationSeconds()) ?? 0
        if duration > Double(theme.outroSeconds) {
            try await spotify.seek(toSeconds: Int(duration.rounded()) - theme.outroSeconds)
        }
        try await spotify.setVolume(theme.volume)  // アンダック（フル音量）
        try await clock.sleep(seconds: Double(theme.outroSeconds))
    }

    /// 発話文を文末（。！？）で区切り、`maxChars` を目安に連結したチャンク列を返す。
    /// 1 チャンクずつ合成・再生し、次チャンクを再生中に先行合成するための分割。
    public static func chunkAnnouncement(_ text: String, maxChars: Int = 120) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if "。！？!?".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current)
        }

        var chunks: [String] = []
        var buffer = ""
        for sentence in sentences {
            if !buffer.isEmpty && buffer.count + sentence.count > maxChars {
                chunks.append(buffer)
                buffer = sentence
            } else {
                buffer += sentence
            }
        }
        if !buffer.isEmpty {
            chunks.append(buffer)
        }
        return chunks
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
