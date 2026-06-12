import Foundation

/// コーナー進行中の出来事（デモ表示・ログ用）。
public enum CornerEvent: Sendable, Equatable {
    case themeSelected(String)
    case letterReady(radioName: String)
    case songPicked(TrackInfo)
    case scriptReady(lineCount: Int, totalCharacters: Int)
    case line(DialogueLine)
    case songStarted(TrackInfo)
}

/// 準備済みコーナー（LLM + TTS 処理の成果物。S10: 先行準備で生成し、本番で消費する）。
public struct PreparedCorner: Sendable, Equatable {
    public let corner: CornerTemplate
    public let song: TrackInfo
    public let script: DialogueScript
    /// 台本各行の合成済み音声（行数と一致。本番の TTS 待ちをゼロにする）。
    public let lineAudio: [Data]

    public init(corner: CornerTemplate, song: TrackInfo, script: DialogueScript, lineAudio: [Data] = []) {
        self.corner = corner
        self.song = song
        self.script = script
        self.lineAudio = lineAudio
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
    private let timeZone: TimeZone
    /// テーマプールからの選択用乱数（0..<count のインデックスを返す。テストでは決定論的に注入）。
    private let randomIndex: @Sendable (Int) -> Int
    private let onEvent: (@Sendable (CornerEvent) -> Void)?

    public init(
        llm: any LLMBackend,
        tts: any TTSBackend,
        audio: any AudioPlayer,
        searcher: any TrackSearcher,
        spotify: any SpotifyController,
        clock: any Clock,
        temperature: Double = 0.9,
        timeZone: TimeZone = .current,
        randomIndex: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<$0) },
        onEvent: (@Sendable (CornerEvent) -> Void)? = nil
    ) {
        self.llm = llm
        self.tts = tts
        self.audio = audio
        self.searcher = searcher
        self.spotify = spotify
        self.clock = clock
        self.temperature = temperature
        self.timeZone = timeZone
        self.randomIndex = randomIndex
        self.onEvent = onEvent
    }

    /// 準備（LLM 処理のみ。音を出さないため失敗時の pause も不要）。
    /// テーマはプールからランダム選択（プール空なら `theme` 固定）。日付・季節コンテキストを
    /// 台本（と letter ではお便り）の生成に注入する（仕様 s12）。
    public func prepare(corner: CornerTemplate, djs: [DjProfile]) async throws -> PreparedCorner {
        let cast = try resolveCast(corner: corner, djs: djs)
        let theme = selectTheme(for: corner)
        onEvent?(.themeSelected(theme))
        let dateContext = SeasonPhrases.dateContext(date: clock.now, timeZone: timeZone)
        let picker = SongPicker(llm: llm, searcher: searcher, temperature: temperature)
        let generator = DialogueScriptGenerator(llm: llm, temperature: temperature)

        // letter: ①お便り生成 → ②リクエスト曲（お便り内容を選曲コンテキストに）→ ③台本（読み上げ + 感想 + 曲振り）
        // free_talk: ①選曲 → ②台本（いずれも曲紹介テキストの生成より前に再生可否を確定する、§3-2）
        let letter: ListenerLetter?
        let songContext: String
        switch corner.format {
        case .letter:
            let generated = try await ListenerLetterGenerator(llm: llm, temperature: temperature)
                .generate(theme: theme, dateContext: dateContext)
            onEvent?(.letterReady(radioName: generated.radioName))
            letter = generated
            songContext = "ラジオコーナー「\(corner.title)」でリスナーのお便りに応えてかけるリクエスト曲。"
                + "お便りの内容: \(generated.body)"
        case .freeTalk:
            letter = nil
            songContext = "ラジオコーナー「\(corner.title)」（テーマ: \(theme)）の締めにかける曲"
        }

        let song = try await picker.pick(SongRequest(
            context: songContext,
            promptHint: corner.songPromptHint,
            fallbackTrackUri: corner.fallbackTrackUri
        ))
        onEvent?(.songPicked(song))

        let script = try await generator.generate(
            corner: corner, djs: cast, song: song,
            theme: theme, dateContext: dateContext, letter: letter
        )
        onEvent?(.scriptReady(lineCount: script.lines.count, totalCharacters: script.totalCharacters))

        // 全行を事前合成（本番の TTS 待ちをゼロに。準備は OP・冒頭曲の再生中に進む）
        var lineAudio: [Data] = []
        lineAudio.reserveCapacity(script.lines.count)
        for line in script.lines {
            lineAudio.append(try await tts.synthesize(text: line.text, speakerId: speakerId(for: line, cast: cast)))
        }

        return PreparedCorner(corner: corner, song: song, script: script, lineAudio: lineAudio)
    }

    private func selectTheme(for corner: CornerTemplate) -> String {
        guard !corner.themePool.isEmpty else { return corner.theme }
        return corner.themePool[randomIndex(corner.themePool.count)]
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
        try await speak(prepared: prepared, cast: cast)

        // 4. 一曲
        try await spotify.play(uri: prepared.song.uri)
        try await spotify.setVolume(prepared.corner.volume)
        onEvent?(.songStarted(prepared.song))
        if prepared.corner.playSeconds > 0 {
            try await clock.sleep(seconds: Double(prepared.corner.playSeconds))
        } else {
            // 曲を終わりまで見届ける（URI 切替確認 + 実終端の検知。早切り・無音の過走を防ぐ、S10 fix）。
            try await spotify.waitForTrackToFinish(of: prepared.song.uri, clock: clock)
        }
    }

    private func speakerId(for line: DialogueLine, cast: [DjProfile]) -> Int {
        cast.first { $0.id == line.djId }?.speakerId ?? cast[0].speakerId
    }

    /// 台本を 1 行ずつ再生する。事前合成済み音声があればそれを使い（TTS 待ちゼロ）、
    /// なければ次の行を現在行の再生中に先行合成する（互換パス）。
    private func speak(prepared: PreparedCorner, cast: [DjProfile]) async throws {
        let lines = prepared.script.lines
        if prepared.lineAudio.count == lines.count {
            for (line, wav) in zip(lines, prepared.lineAudio) {
                onEvent?(.line(line))
                try await audio.play(wav)
            }
            return
        }

        guard let first = lines.first else { return }
        var pending = try await tts.synthesize(text: first.text, speakerId: speakerId(for: first, cast: cast))
        for index in lines.indices {
            onEvent?(.line(lines[index]))
            if index + 1 < lines.count {
                let next = lines[index + 1]
                async let prefetch = tts.synthesize(text: next.text, speakerId: speakerId(for: next, cast: cast))
                try await audio.play(pending)
                pending = try await prefetch
            } else {
                try await audio.play(pending)
            }
        }
    }
}
