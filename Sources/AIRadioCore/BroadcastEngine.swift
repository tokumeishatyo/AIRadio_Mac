import Foundation

/// 放送進行中の出来事（デモ表示・ログ用）。
public enum BroadcastEvent: Sendable, Equatable {
    case segmentStarted(index: Int, kind: SegmentKind)
    case segmentFinished(index: Int, kind: SegmentKind)
    /// セグメント失敗（スキップして継続）。code / detail は基となったエラーのコードと詳細。
    case segmentFailed(index: Int, kind: SegmentKind, code: String, detail: String)
    /// song セグメントの再生開始（曲名不明 = フォールバック曲のときは title/artist 空）。
    case songStarted(index: Int, track: TrackInfo)
    case broadcastFinished
}

/// 番組フォーマット（`Program`）に従ってセグメントを順次実行する放送エンジン。
/// - fail-tolerant: セグメント失敗は `segmentFailed` を通知して次へ（放送継続）。
/// - キャンセル（`Task.cancel()`）は即時伝播し、後続セグメントは実行しない。
/// - 正常・失敗・キャンセルのいずれでも最後は必ず `pause()`（完全静寂、CLAUDE.md §3-1）。
/// - **切れ目ない放送（S10）**: 放送開始時に全 song の選曲・全 talk の準備（LLM）を並行起動し、
///   放送中の LLM 待ちデッドエアをなくす。放送開始前の無音は許容。
public struct BroadcastEngine: Sendable {
    private let themes: BroadcastThemes
    private let themeSequencer: any ThemeSequencing
    private let cornerRunner: any CornerRunning
    private let newsProvider: any AnnouncementProviding
    private let songPicker: (any SongPicking)?
    private let spotify: any SpotifyController
    private let clock: any Clock
    private let timeZone: TimeZone
    private let onEvent: (@Sendable (BroadcastEvent) -> Void)?

    public init(
        themes: BroadcastThemes,
        themeSequencer: any ThemeSequencing,
        cornerRunner: any CornerRunning,
        newsProvider: any AnnouncementProviding,
        songPicker: (any SongPicking)? = nil,
        spotify: any SpotifyController,
        clock: any Clock,
        timeZone: TimeZone = .current,
        onEvent: (@Sendable (BroadcastEvent) -> Void)? = nil
    ) {
        self.themes = themes
        self.themeSequencer = themeSequencer
        self.cornerRunner = cornerRunner
        self.newsProvider = newsProvider
        self.songPicker = songPicker
        self.spotify = spotify
        self.clock = clock
        self.timeZone = timeZone
        self.onEvent = onEvent
    }

    public func run(program: Program, corners: [CornerTemplate], djs: [DjProfile]) async throws {
        // fail-fast 検証（音を出す前に設定不整合を弾く）。
        guard let anchor = djs.first(where: { $0.id == program.anchorDjId }) else {
            throw ConfigError.missingField("program.anchor_dj_id に未定義の DJ: \(program.anchorDjId)")
        }
        let resolved: [(segment: ProgramSegment, corner: CornerTemplate?, speakerId: Int)] =
            try program.segments.map { segment in
                // テーマ系セグメントの読み上げ DJ（未指定は anchor）。
                let speaker: DjProfile
                if let djId = segment.djId {
                    guard let dj = djs.first(where: { $0.id == djId }) else {
                        throw ConfigError.missingField("program.segments[].dj_id に未定義の DJ: \(djId)")
                    }
                    speaker = dj
                } else {
                    speaker = anchor
                }
                if segment.kind == .song, segment.song == nil {
                    throw ConfigError.missingField("program.segments[].song（song セグメントの設定）")
                }
                guard segment.kind == .talk else { return (segment, nil, speaker.speakerId) }
                guard let id = segment.cornerId, let corner = corners.first(where: { $0.id == id }) else {
                    throw ConfigError.missingField("program.segments[].corner_id に未定義のコーナー: \(segment.cornerId ?? "(なし)")")
                }
                return (segment, corner, speaker.speakerId)
            }

        // 先行準備（S10）: 全 song の選曲・全 talk の準備を並行起動（まだ音は出ない）。
        var cornerPreparations: [Int: Task<PreparedCorner, any Error>] = [:]
        var songPicks: [Int: Task<TrackInfo, Never>] = [:]
        for (index, entry) in resolved.enumerated() {
            switch entry.segment.kind {
            case .talk:
                let runner = cornerRunner
                let corner = entry.corner!
                cornerPreparations[index] = Task { try await runner.prepare(corner: corner, djs: djs) }
            case .song:
                let picker = songPicker
                let spec = entry.segment.song!
                let context = "ラジオ番組「\(program.title)」のオープニング直後にかける、本日の 1 曲目"
                songPicks[index] = Task {
                    // 選曲失敗（LLM 不調等）はフォールバック曲に倒して放送は止めない。
                    let request = SongRequest(
                        context: context, promptHint: spec.promptHint, fallbackTrackUri: spec.fallbackTrackUri)
                    if let picker, let track = try? await picker.pick(request) {
                        return track
                    }
                    return TrackInfo(uri: spec.fallbackTrackUri, title: "", artist: "")
                }
            default:
                break
            }
        }
        let cancelPreparations: @Sendable () -> Void = { [cornerPreparations, songPicks] in
            cornerPreparations.values.forEach { $0.cancel() }
            songPicks.values.forEach { $0.cancel() }
        }

        // 準備 Task はエンジンのキャンセルを継承しない（非構造化）ため、停止時に明示キャンセルする。
        try await withTaskCancellationHandler {
            defer { cancelPreparations() }

            // 最初の song の確定を待つ（{first_song} を OP の曲振りに使うため。放送開始前の無音許容ゾーン）。
            var extraValues = ["first_song": "本日の一曲"]
            if let firstSongIndex = resolved.firstIndex(where: { $0.segment.kind == .song }),
               let pick = songPicks[firstSongIndex] {
                let track = await pick.value
                if !track.title.isEmpty {
                    extraValues["first_song"] = "\(track.artist)で、「\(track.title)」"
                }
            }
            try Task.checkCancellation()

            do {
                for (index, entry) in resolved.enumerated() {
                    try Task.checkCancellation()
                    onEvent?(.segmentStarted(index: index, kind: entry.segment.kind))
                    do {
                        try await perform(
                            index: index,
                            entry: entry,
                            djs: djs,
                            extraValues: extraValues,
                            cornerPreparations: cornerPreparations,
                            songPicks: songPicks
                        )
                        onEvent?(.segmentFinished(index: index, kind: entry.segment.kind))
                    } catch {
                        // キャンセル中は Infra 層が URLSession の取消をドメインエラーにラップして
                        // 投げてくることがある（例: E-SPT-AUTH-FAILED）。スキップと誤判定せず即時停止する。
                        if error is CancellationError || Task.isCancelled {
                            throw CancellationError()
                        }
                        // スキップして放送継続（fail-tolerant、E-RTM-SEGMENT-FAILED-001）。
                        let radioError = error as? RadioError
                        let code = radioError?.code ?? String(describing: type(of: error))
                        onEvent?(.segmentFailed(
                            index: index,
                            kind: entry.segment.kind,
                            code: code,
                            detail: radioError?.message ?? String(describing: error)
                        ))
                        // critical セグメント（既定の番組では OP）の失敗は放送中止。
                        if entry.segment.critical {
                            throw BroadcastError.segmentFailed("\(entry.segment.kind.rawValue): \(code)")
                        }
                    }
                }
            } catch {
                await spotify.pauseIgnoringCancellation(restoringVolume: themes.opening.theme.volume)
                throw error
            }
            // 各セグメントも自前で pause するが、エンジンでも重ねて完全静寂を保証する。
            try? await spotify.pause()
            onEvent?(.broadcastFinished)
        } onCancel: {
            cancelPreparations()
        }
    }

    private func perform(
        index: Int,
        entry: (segment: ProgramSegment, corner: CornerTemplate?, speakerId: Int),
        djs: [DjProfile],
        extraValues: [String: String],
        cornerPreparations: [Int: Task<PreparedCorner, any Error>],
        songPicks: [Int: Task<TrackInfo, Never>]
    ) async throws {
        switch entry.segment.kind {
        case .opening:
            try await themeSequencer.run(
                theme: themes.opening.theme,
                announcement: expand(themes.opening.announcement, extra: extraValues),
                speakerId: entry.speakerId
            )
        case .song:
            // 選曲は先行準備済み（OP 前に確定している）。
            let spec = entry.segment.song!
            let track = await songPicks[index]!.value
            try await spotify.play(uri: track.uri)
            try await spotify.setVolume(spec.volume)
            onEvent?(.songStarted(index: index, track: track))
            let playSeconds: Double
            if spec.playSeconds > 0 {
                playSeconds = Double(spec.playSeconds)
            } else {
                // URI 切替確認つきの残り秒数（切替直後に前の曲の長さを読むと早切りする）。
                playSeconds = try await spotify.remainingSeconds(of: track.uri, clock: clock)
            }
            try await clock.sleep(seconds: playSeconds)
            try await spotify.pause()
        case .talk:
            // 先行準備の完了を待つ（通常は冒頭曲の再生中に完了しており待ち時間ゼロ）。
            let prepared = try await cornerPreparations[index]!.value
            try await cornerRunner.run(prepared: prepared, djs: djs)
        case .news:
            // Provider が {news}/{weather} を展開した原稿に、発話直前の時刻を二段展開する。
            let script = await newsProvider.announcement()
            try await themeSequencer.run(
                theme: themes.news,
                announcement: expand(script, extra: extraValues),
                speakerId: entry.speakerId
            )
        case .ending:
            try await themeSequencer.run(
                theme: themes.ending.theme,
                announcement: expand(themes.ending.announcement, extra: extraValues),
                speakerId: entry.speakerId
            )
        }
    }

    /// 時刻プレースホルダ + 番組コンテキスト（{first_song} 等）の展開。
    /// 発話直前に呼ぶことで時報として正確になる（仕様 s8 §3 / s10 §2）。
    private func expand(_ template: String, extra: [String: String]) -> String {
        var values = TimePhrases.values(date: clock.now, greetings: themes.greetings, timeZone: timeZone)
        values.merge(extra) { _, new in new }
        return TemplateExpander.expand(template, values: values)
    }
}
