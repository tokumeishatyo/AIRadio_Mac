import Foundation

/// コーナー進行中の出来事（デモ表示・ログ用）。
public enum CornerEvent: Sendable, Equatable {
    case themeSelected(String)
    case letterReady(radioName: String)
    /// ゲストコーナーで迎えるゲストが確定（仕様 s14）。
    case guestReady(name: String)
    case songPicked(TrackInfo)
    case scriptReady(lineCount: Int, totalCharacters: Int)
    /// 時報リード文（発話直前に時刻展開した実テキスト。仕様 s13.5 §5）。
    case leadIn(String)
    case line(DialogueLine)
    case songStarted(TrackInfo)
    /// 締め曲（フル再生時）の終端検知の理由（途中切り診断用、常時ログ）。
    case songFinished(reason: TrackFinishReason)
}

/// 準備済みコーナー（LLM + TTS 処理の成果物。S10: 先行準備で生成し、本番で消費する）。
public struct PreparedCorner: Sendable, Equatable {
    public let corner: CornerTemplate
    public let song: TrackInfo
    public let script: DialogueScript
    /// 台本各行の合成済み音声（行数と一致。本番の TTS 待ちをゼロにする）。
    public let lineAudio: [Data]
    /// 実際に使った出演者（順序付き・先頭＝メイン）。run で台本行→話者を一貫解決するため保持。
    public let castDjIds: [String]
    /// 本編前に読み上げる時報リード文テンプレート（時刻プレースホルダ含む。発話直前に展開。nil＝頭出しなし）。
    public let leadIn: String?
    /// 時報リード文の読み手（その日のメイン）の speaker id。
    public let leadInSpeakerId: Int
    /// ゲストコーナーで迎えたゲスト（cast 末尾の出演者。`castDjIds` には含めず別持ち＝djs に居ないため。仕様 s14）。
    public let guest: DjProfile?

    public init(
        corner: CornerTemplate,
        song: TrackInfo,
        script: DialogueScript,
        lineAudio: [Data] = [],
        castDjIds: [String] = [],
        leadIn: String? = nil,
        leadInSpeakerId: Int = 0,
        guest: DjProfile? = nil
    ) {
        self.corner = corner
        self.song = song
        self.script = script
        self.lineAudio = lineAudio
        self.castDjIds = castDjIds
        self.leadIn = leadIn
        self.leadInSpeakerId = leadInSpeakerId
        self.guest = guest
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
    /// 出演者は context.castDjIds（その日の編成・先頭＝メイン）で上書き、冒頭は挨拶、他は時報リード文（仕様 s13.5）。
    public func prepare(corner: CornerTemplate, djs: [DjProfile], context: CornerContext = CornerContext()) async throws -> PreparedCorner {
        let castIds = context.castDjIds.isEmpty ? corner.djIds : context.castDjIds
        let baseCast = try resolveCast(ids: castIds, djs: djs)
        let theme = selectTheme(for: corner)
        onEvent?(.themeSelected(theme))
        let dateContext = SeasonPhrases.dateContext(date: clock.now, timeZone: timeZone)
        let picker = SongPicker(llm: llm, searcher: searcher, temperature: temperature)
        let generator = DialogueScriptGenerator(llm: llm, temperature: temperature)

        // ゲストコーナー（format: guest）のときだけ、その日の編成の末尾にゲストを足す（cast に居ないため別持ち）。
        let guest: DjProfile? = (corner.format == .guest) ? context.guest : nil
        if let guest { onEvent?(.guestReady(name: guest.name)) }
        let cast = guest.map { baseCast + [$0] } ?? baseCast

        // letter: ①お便り生成 → ②リクエスト曲（お便り内容を選曲コンテキストに）→ ③台本（読み上げ + 感想 + 曲振り）
        // guest/free_talk: ①選曲 → ②台本（いずれも曲紹介テキストの生成より前に再生可否を確定する、§3-2）
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
        case .guest:
            letter = nil
            songContext = "ラジオコーナー「\(corner.title)」（テーマ: \(theme)）でゲストを迎えての会話の締めにかける曲"
        case .freeTalk:
            letter = nil
            songContext = "ラジオコーナー「\(corner.title)」（テーマ: \(theme)）の締めにかける曲"
        case .artistFeature:
            // アーティスト特集は専用の ArtistFeatureEngine で実行する（仕様 s15）。CornerEngine には来ない想定。
            throw ConfigError.missingField("artist_feature は CornerEngine では実行しない（ArtistFeatureEngine を使う）")
        }

        let song = try await picker.pick(SongRequest(
            context: songContext,
            promptHint: corner.songPromptHint,
            fallbackTrackUri: corner.fallbackTrackUri
        ))
        onEvent?(.songPicked(song))

        let script = try await generator.generate(
            corner: corner, djs: cast, song: song,
            theme: theme, dateContext: dateContext, letter: letter,
            greeting: context.greeting, guest: guest
        )
        onEvent?(.scriptReady(lineCount: script.lines.count, totalCharacters: script.totalCharacters))

        // 全行を事前合成（本番の TTS 待ちをゼロに。準備は OP・冒頭曲の再生中に進む）
        var lineAudio: [Data] = []
        lineAudio.reserveCapacity(script.lines.count)
        for line in script.lines {
            lineAudio.append(try await tts.synthesize(text: line.text, speakerId: speakerId(for: line, cast: cast)))
        }

        // 時報リード文は事前合成しない（時刻が再生時点でずれるため）。テンプレートのまま持ち、run で発話直前展開。
        // {theme}/{guest} は準備時点で確定済みなのでここで埋め、時刻プレースホルダのみ残す（仕様 s14）。
        var leadIn = (context.leadIn?.isEmpty == false) ? context.leadIn : nil
        if var filled = leadIn {
            filled = filled.replacingOccurrences(of: "{theme}", with: theme)
            if let guest { filled = filled.replacingOccurrences(of: "{guest}", with: guest.name) }
            leadIn = filled
        }
        return PreparedCorner(
            corner: corner, song: song, script: script, lineAudio: lineAudio,
            castDjIds: castIds, leadIn: leadIn, leadInSpeakerId: baseCast.first?.speakerId ?? 0,
            guest: guest
        )
    }

    private func selectTheme(for corner: CornerTemplate) -> String {
        guard !corner.themePool.isEmpty else { return corner.theme }
        return corner.themePool[randomIndex(corner.themePool.count)]
    }

    /// 本番（発話 + 一曲。正常・例外・キャンセルいずれも最後は必ず pause）。
    public func run(prepared: PreparedCorner, djs: [DjProfile]) async throws {
        let castIds = prepared.castDjIds.isEmpty ? prepared.corner.djIds : prepared.castDjIds
        do {
            // ゲストは djs に居ないため prepared から末尾に補う（準備時と同じ並び）。
            var cast = try resolveCast(ids: castIds, djs: djs)
            if let guest = prepared.guest { cast.append(guest) }
            try await perform(prepared: prepared, cast: cast)
        } catch {
            // 完全静寂（§3-1）: エラー / キャンセルでも必ず曲を止め、音量をフルに戻す。
            await spotify.pauseIgnoringCancellation(restoringVolume: prepared.corner.volume)
            throw error
        }
        try await spotify.pause()
    }

    private func resolveCast(ids: [String], djs: [DjProfile]) throws -> [DjProfile] {
        try ids.map { id in
            guard let dj = djs.first(where: { $0.id == id }) else {
                throw ConfigError.missingField("コーナーの出演 DJ が未定義: \(id)")
            }
            return dj
        }
    }

    private func perform(prepared: PreparedCorner, cast: [DjProfile]) async throws {
        // 0. 時報リード文（あれば）。発話直前に時刻を展開し、その場で合成＝再生時点で正確（仕様 s13.5 §5）。
        // リード文の合成/再生が一過性に失敗しても、準備済みの本編＋曲は流す（リード文は付加要素）。
        // ただしキャンセルは握り潰さず伝播する（完全静寂の保証、CLAUDE.md §3-1）。
        if let leadIn = prepared.leadIn, !leadIn.isEmpty {
            let values = TimePhrases.values(date: clock.now, timeZone: timeZone)
            let text = TemplateExpander.expand(leadIn, values: values)
            onEvent?(.leadIn(text))
            do {
                let wav = try await tts.synthesize(text: text, speakerId: prepared.leadInSpeakerId)
                try await audio.play(wav)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                // 一過性のリード文失敗はスキップして本編へ（fail-tolerant）。
            }
        }

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
            let reason = try await spotify.waitForTrackToFinish(of: prepared.song.uri, clock: clock)
            onEvent?(.songFinished(reason: reason))
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
