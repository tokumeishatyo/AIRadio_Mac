import Foundation

/// コーナー進行中の出来事（デモ表示・ログ用）。
public enum CornerEvent: Sendable, Equatable {
    case songPicked(TrackInfo)
    case scriptReady(lineCount: Int, totalCharacters: Int)
    case line(DialogueLine)
    case songStarted(TrackInfo)
}

/// 準備済みコーナー（LLM 処理の成果物。S10: 先行準備で生成し、本番で消費する）。
public struct PreparedCorner: Sendable, Equatable {
    public let corner: CornerTemplate
    public let song: TrackInfo
    public let script: DialogueScript

    public init(corner: CornerTemplate, song: TrackInfo, script: DialogueScript) {
        self.corner = corner
        self.song = song
        self.script = script
    }
}

/// コーナー 1 本の進行。**準備（LLM 処理、無音）と本番（発話 + 曲）の 2 段**:
/// 1. prepare: 選曲（プレフライト先行、CLAUDE.md §3-2）→ 台本生成（確定曲を締めで紹介）
/// 2. run(prepared:): 発話（次行を先行合成）→ 一曲 → 必ず pause（CLAUDE.md §3-1）
/// 先行準備（S10）により、本番開始時に LLM 待ちのデッドエアが発生しない。
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

    /// 準備（LLM 処理のみ。音を出さないため失敗時の pause も不要）。
    public func prepare(corner: CornerTemplate, djs: [DjProfile]) async throws -> PreparedCorner {
        let cast = try resolveCast(corner: corner, djs: djs)

        // 1. 選曲（曲紹介テキストの生成より前に再生可否を確定する）
        let picker = SongPicker(llm: llm, searcher: searcher, temperature: temperature)
        let song = try await picker.pick(SongRequest(
            context: "ラジオコーナー「\(corner.title)」（テーマ: \(corner.theme)）の締めにかける曲",
            promptHint: corner.songPromptHint,
            fallbackTrackUri: corner.fallbackTrackUri
        ))
        onEvent?(.songPicked(song))

        // 2. 台本生成
        let generator = DialogueScriptGenerator(llm: llm, temperature: temperature)
        let script = try await generator.generate(corner: corner, djs: cast, song: song)
        onEvent?(.scriptReady(lineCount: script.lines.count, totalCharacters: script.totalCharacters))

        return PreparedCorner(corner: corner, song: song, script: script)
    }

    /// 本番（発話 + 一曲。正常・例外・キャンセルいずれも最後は必ず pause）。
    public func run(prepared: PreparedCorner, djs: [DjProfile]) async throws {
        do {
            try await perform(prepared: prepared, cast: try resolveCast(corner: prepared.corner, djs: djs))
        } catch {
            // 完全静寂（§3-1）: エラー / キャンセルでも必ず曲を止め、音量をフルに戻す。
            await spotify.pauseIgnoringCancellation(restoringVolume: prepared.corner.volume)
            throw error
        }
        try await spotify.pause()
    }

    private func resolveCast(corner: CornerTemplate, djs: [DjProfile]) throws -> [DjProfile] {
        try corner.djIds.map { id in
            guard let dj = djs.first(where: { $0.id == id }) else {
                throw ConfigError.missingField("corners.dj_ids に未定義の DJ: \(id)")
            }
            return dj
        }
    }

    private func perform(prepared: PreparedCorner, cast: [DjProfile]) async throws {
        // 3. 発話
        try await speak(script: prepared.script, cast: cast)

        // 4. 一曲
        try await spotify.play(uri: prepared.song.uri)
        try await spotify.setVolume(prepared.corner.volume)
        onEvent?(.songStarted(prepared.song))
        let playSeconds: Double
        if prepared.corner.playSeconds > 0 {
            playSeconds = Double(prepared.corner.playSeconds)
        } else {
            // URI 切替確認つきの残り秒数（切替直後に前の曲の長さを読むと早切りする、S10 fix）。
            playSeconds = try await spotify.remainingSeconds(of: prepared.song.uri, clock: clock)
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
