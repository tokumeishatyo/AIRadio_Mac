import Foundation

/// コーナー進行中の出来事（デモ表示・ログ用）。
public enum CornerEvent: Sendable, Equatable {
    case songPicked(TrackInfo)
    case scriptReady(lineCount: Int, totalCharacters: Int)
    case line(DialogueLine)
    case songStarted(TrackInfo)
}

/// コーナー 1 本の進行。基本パターン:
/// 1. 選曲（プレフライト先行、CLAUDE.md §3-2）
/// 2. 台本生成（確定済みの曲を会話の締めで紹介させる）
/// 3. 発話（1 行ずつ、その DJ の声で合成 → 再生。次行は再生中に先行合成）
/// 4. 一曲（`play_seconds` 秒、0 なら曲の長さぶん）
/// 5. 後始末（正常・例外・キャンセルいずれも最後は必ず pause、CLAUDE.md §3-1）
public struct CornerEngine: CornerRunning, Sendable {
    private let llm: any LLMBackend
    private let tts: any TTSBackend
    private let audio: any AudioPlayer
    private let searcher: any TrackSearcher
    private let spotify: any SpotifyController
    private let clock: any Clock
    private let temperature: Double
    private let onEvent: (@Sendable (CornerEvent) -> Void)?

    public init(
        llm: any LLMBackend,
        tts: any TTSBackend,
        audio: any AudioPlayer,
        searcher: any TrackSearcher,
        spotify: any SpotifyController,
        clock: any Clock,
        temperature: Double = 0.9,
        onEvent: (@Sendable (CornerEvent) -> Void)? = nil
    ) {
        self.llm = llm
        self.tts = tts
        self.audio = audio
        self.searcher = searcher
        self.spotify = spotify
        self.clock = clock
        self.temperature = temperature
        self.onEvent = onEvent
    }

    public func run(corner: CornerTemplate, djs: [DjProfile]) async throws {
        do {
            try await perform(corner: corner, djs: djs)
        } catch {
            // 完全静寂（§3-1）: エラー / キャンセルでも必ず曲を止める。
            try? await spotify.pause()
            throw error
        }
        try await spotify.pause()
    }

    private func perform(corner: CornerTemplate, djs: [DjProfile]) async throws {
        let cast = try corner.djIds.map { id in
            guard let dj = djs.first(where: { $0.id == id }) else {
                throw ConfigError.missingField("corners.dj_ids に未定義の DJ: \(id)")
            }
            return dj
        }

        // 1. 選曲（曲紹介テキストの生成より前に再生可否を確定する）
        let picker = SongPicker(llm: llm, searcher: searcher, temperature: temperature)
        let song = try await picker.pick(corner: corner)
        onEvent?(.songPicked(song))

        // 2. 台本生成
        let generator = DialogueScriptGenerator(llm: llm, temperature: temperature)
        let script = try await generator.generate(corner: corner, djs: cast, song: song)
        onEvent?(.scriptReady(lineCount: script.lines.count, totalCharacters: script.totalCharacters))

        // 3. 発話
        try await speak(script: script, cast: cast)

        // 4. 一曲
        try await spotify.play(uri: song.uri)
        try await spotify.setVolume(corner.volume)
        onEvent?(.songStarted(song))
        let playSeconds: Double
        if corner.playSeconds > 0 {
            playSeconds = Double(corner.playSeconds)
        } else {
            playSeconds = try await spotify.currentTrackDurationSeconds()
        }
        try await clock.sleep(seconds: playSeconds)
    }

    /// 台本を 1 行ずつ再生する。次の行は現在行の再生中に先行合成し、行間の無音を最小化する。
    private func speak(script: DialogueScript, cast: [DjProfile]) async throws {
        func speakerId(for line: DialogueLine) -> Int {
            cast.first { $0.id == line.djId }?.speakerId ?? cast[0].speakerId
        }

        let lines = script.lines
        guard let first = lines.first else { return }
        var pending = try await tts.synthesize(text: first.text, speakerId: speakerId(for: first))
        for index in lines.indices {
            onEvent?(.line(lines[index]))
            if index + 1 < lines.count {
                let next = lines[index + 1]
                async let prefetch = tts.synthesize(text: next.text, speakerId: speakerId(for: next))
                try await audio.play(pending)
                pending = try await prefetch
            } else {
                try await audio.play(pending)
            }
        }
    }
}
