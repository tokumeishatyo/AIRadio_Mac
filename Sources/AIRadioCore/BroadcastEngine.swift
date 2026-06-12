import Foundation

/// 放送進行中の出来事（デモ表示・ログ用）。
public enum BroadcastEvent: Sendable, Equatable {
    case segmentStarted(index: Int, kind: SegmentKind)
    case segmentFinished(index: Int, kind: SegmentKind)
    /// セグメント失敗（スキップして継続）。code / detail は基となったエラーのコードと詳細。
    case segmentFailed(index: Int, kind: SegmentKind, code: String, detail: String)
    /// song セグメントの再生開始（曲名不明 = フォールバック曲のときは title/artist 空）。
    case songStarted(index: Int, track: TrackInfo)
    /// song セグメント（フル再生）の終端検知の理由（途中切り診断用、常時ログ）。
    case songFinished(index: Int, reason: TrackFinishReason)
    /// 「ED で終了」要求を受け付けた（仕様 s13 §4）。
    case endingRequested
    case broadcastFinished
}

/// 番組（`ProgramPlan`）のセグメントを順次実行する放送エンジン。
/// - fail-tolerant: セグメント失敗は `segmentFailed` を通知して次へ（放送継続）。
/// - キャンセル（`Task.cancel()`）は即時伝播し、後続セグメントは実行しない。
/// - 正常・失敗・キャンセルのいずれでも最後は必ず `pause()`（完全静寂、CLAUDE.md §3-1）。
/// - **ローリング先行準備（S13）**: 実行中セグメントの先 2 つまでの準備（選曲 / LLM / TTS）を
///   保持する。エンドレス番組でも準備が際限なく積み上がらず、ニュースは出現のたびに生成される。
/// - **ED で終了（S13）**: `BroadcastControl.requestEnding()` を受けると、現在のセグメント
///   （+ 準備完了済みの直後トーク）を流したあと残りを飛ばして ED で締める。
public struct BroadcastEngine: Sendable {
    /// 実行中セグメントの先いくつまで準備するか（仕様 s13 §3）。
    public static let preparationWindow = 2

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

    public func run(
        plan: ProgramPlan,
        corners: [CornerTemplate],
        djs: [DjProfile],
        control: BroadcastControl? = nil
    ) async throws {
        // fail-fast 検証（音を出す前に設定不整合を弾く）。
        guard let anchor = djs.first(where: { $0.id == plan.anchorDjId }) else {
            throw ConfigError.missingField("program.anchor_dj_id に未定義の DJ: \(plan.anchorDjId)")
        }
        for cornerId in [plan.blueprint.talkCornerId, plan.blueprint.letterCornerId] {
            guard corners.contains(where: { $0.id == cornerId }) else {
                throw ConfigError.missingField("program.talk/letter.corner_id に未定義のコーナー: \(cornerId)")
            }
        }
        if let newsDjId = plan.blueprint.newsDjId {
            guard djs.contains(where: { $0.id == newsDjId }) else {
                throw ConfigError.missingField("program.news.dj_id に未定義の DJ: \(newsDjId)")
            }
        }

        // 準備 Task はエンジンのキャンセルを継承しない（非構造化）ため、停止時に明示キャンセルする。
        let ledger = PreparationLedger()
        try await withTaskCancellationHandler {
            defer { ledger.cancelAll() }
            try await broadcast(plan: plan, corners: corners, djs: djs, anchor: anchor, control: control, ledger: ledger)
        } onCancel: {
            ledger.cancelAll()
        }
    }

    // MARK: - 放送本体

    private func broadcast(
        plan: ProgramPlan,
        corners: [CornerTemplate],
        djs: [DjProfile],
        anchor: DjProfile,
        control: BroadcastControl?,
        ledger: PreparationLedger
    ) async throws {
        // ローリング準備の起動（単一消費者なので進捗はローカル変数で追う）。
        var preparationStartedThrough = -1
        func ensurePrepared(through target: Int) {
            while preparationStartedThrough < target {
                preparationStartedThrough += 1
                let index = preparationStartedThrough
                guard let segment = plan.segment(at: index) else { return }
                startPreparation(of: segment, at: index, plan: plan, corners: corners, djs: djs, ledger: ledger)
            }
        }

        // 最初の song の確定を待つ（{first_song} を OP の曲振りに使うため。放送開始前の無音許容ゾーン）。
        ensurePrepared(through: Self.preparationWindow)
        var extraValues = ["first_song": "本日の一曲"]
        if plan.segment(at: 1)?.kind == .song, let pick = ledger.songTask(at: 1) {
            let track = await pick.value
            if !track.title.isEmpty {
                extraValues["first_song"] = "\(track.artist)で、「\(track.title)」"
            }
        }
        try Task.checkCancellation()

        do {
            var index = 0
            while let segment = plan.segment(at: index) {
                try Task.checkCancellation()
                ensurePrepared(through: index + Self.preparationWindow)
                try await runSegment(segment, at: index, djs: djs, anchor: anchor, extraValues: extraValues, ledger: ledger)
                ledger.discard(index)

                // 「ED で終了」: 直後のトーク（free_talk）が準備完了済みならそれだけ流し、
                // 残り（お便り / ニュース含む）はすべて飛ばして ED（仕様 s13 §4）。
                if let control, control.isEndingRequested, segment.kind != .ending {
                    onEvent?(.endingRequested)
                    var edIndex = index + 1
                    if let next = plan.segment(at: edIndex),
                       next.kind == .talk,
                       next.cornerId == plan.blueprint.talkCornerId,
                       ledger.isCornerPrepared(at: edIndex) {
                        ledger.cancelAll(keeping: edIndex)   // 窓の外を捨てる
                        try await runSegment(next, at: edIndex, djs: djs, anchor: anchor, extraValues: extraValues, ledger: ledger)
                        ledger.discard(edIndex)
                        edIndex += 1
                    } else {
                        ledger.cancelAll()
                    }
                    // ED を流して終了（エンドレスは plan に ED がないため合成。有限も前倒しで同じ）。
                    try await runSegment(
                        ProgramSegment(kind: .ending), at: edIndex,
                        djs: djs, anchor: anchor, extraValues: extraValues, ledger: ledger)
                    break
                }
                index += 1
            }
        } catch {
            await spotify.pauseIgnoringCancellation(restoringVolume: themes.opening.theme.volume)
            throw error
        }
        // 各セグメントも自前で pause するが、エンジンでも重ねて完全静寂を保証する。
        try? await spotify.pause()
        onEvent?(.broadcastFinished)
    }

    /// セグメント 1 本の実行（fail-tolerant + critical 判定 + キャンセル即時伝播）。
    private func runSegment(
        _ segment: ProgramSegment,
        at index: Int,
        djs: [DjProfile],
        anchor: DjProfile,
        extraValues: [String: String],
        ledger: PreparationLedger
    ) async throws {
        onEvent?(.segmentStarted(index: index, kind: segment.kind))
        do {
            try await perform(segment, at: index, djs: djs, anchor: anchor, extraValues: extraValues, ledger: ledger)
            onEvent?(.segmentFinished(index: index, kind: segment.kind))
        } catch {
            // キャンセル中は Infra 層が URLSession の取消をドメインエラーにラップして
            // 投げてくることがある（例: E-SPT-AUTH-FAILED）。スキップと誤判定せず即時停止する。
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            // 失敗したセグメントが音を出したまま次へ進まないよう、ここでも静寂を保証する。
            await spotify.pauseIgnoringCancellation(restoringVolume: themes.opening.theme.volume)
            // スキップして放送継続（fail-tolerant、E-RTM-SEGMENT-FAILED-001）。
            let radioError = error as? RadioError
            let code = radioError?.code ?? String(describing: type(of: error))
            onEvent?(.segmentFailed(
                index: index,
                kind: segment.kind,
                code: code,
                detail: radioError?.message ?? String(describing: error)
            ))
            // critical セグメント（既定の番組では OP）の失敗は放送中止。
            if segment.critical {
                throw BroadcastError.segmentFailed("\(segment.kind.rawValue): \(code)")
            }
        }
    }

    private func perform(
        _ segment: ProgramSegment,
        at index: Int,
        djs: [DjProfile],
        anchor: DjProfile,
        extraValues: [String: String],
        ledger: PreparationLedger
    ) async throws {
        let speaker = try resolveSpeaker(segment.djId, djs: djs, anchor: anchor)
        switch segment.kind {
        case .opening:
            try await themeSequencer.run(
                theme: themes.opening.theme,
                announcement: expand(themes.opening.announcement, extra: extraValues),
                speakerId: speaker.speakerId
            )
        case .song:
            // 選曲は先行準備済み（OP 前に確定している）。
            let spec = segment.song!
            let track = await ledger.songTask(at: index)!.value
            try await spotify.play(uri: track.uri)
            try await spotify.setVolume(spec.volume)
            onEvent?(.songStarted(index: index, track: track))
            if spec.playSeconds > 0 {
                try await clock.sleep(seconds: Double(spec.playSeconds))
            } else {
                // 曲を終わりまで見届ける（URI 切替確認 + 実終端の検知。早切り・無音の過走を防ぐ）。
                let reason = try await spotify.waitForTrackToFinish(of: track.uri, clock: clock)
                onEvent?(.songFinished(index: index, reason: reason))
            }
            try await spotify.pause()
        case .talk:
            // 先行準備の完了を待つ（通常は前のセグメントの再生中に完了しており待ち時間ゼロ）。
            guard let preparation = ledger.cornerTask(at: index) else {
                throw BroadcastError.segmentFailed("talk: 準備タスクがありません（index \(index)）")
            }
            let prepared = try await preparation.value
            try await cornerRunner.run(prepared: prepared, djs: djs)
        case .news:
            // 原稿は出現のたびに先行準備で生成（長時間放送でニュースが更新される、s13 §3）。
            guard let script = await ledger.newsTask(at: index)?.value else {
                throw BroadcastError.segmentFailed("news: 準備タスクがありません（index \(index)）")
            }
            try await themeSequencer.run(
                theme: themes.news,
                announcement: expand(script, extra: extraValues),
                speakerId: speaker.speakerId
            )
        case .ending:
            try await themeSequencer.run(
                theme: themes.ending.theme,
                announcement: expand(themes.ending.announcement, extra: extraValues),
                speakerId: speaker.speakerId
            )
        }
    }

    private func startPreparation(
        of segment: ProgramSegment,
        at index: Int,
        plan: ProgramPlan,
        corners: [CornerTemplate],
        djs: [DjProfile],
        ledger: PreparationLedger
    ) {
        switch segment.kind {
        case .talk:
            // corner は fail-fast 検証済み（talk/letter とも実在する）。
            let corner = corners.first { $0.id == segment.cornerId }!
            let runner = cornerRunner
            ledger.addCorner(at: index, Task {
                let prepared = try await runner.prepare(corner: corner, djs: djs)
                ledger.markCornerPrepared(at: index)
                return prepared
            })
        case .news:
            let provider = newsProvider
            ledger.addNews(at: index, Task { await provider.announcement() })
        case .song:
            let picker = songPicker
            let spec = segment.song!
            let context = "ラジオ番組「\(plan.title)」のオープニング直後にかける、本日の 1 曲目"
            ledger.addSong(at: index, Task {
                // 選曲失敗（LLM 不調等）はフォールバック曲に倒して放送は止めない。
                let request = SongRequest(
                    context: context, promptHint: spec.promptHint, fallbackTrackUri: spec.fallbackTrackUri)
                if let picker, let track = try? await picker.pick(request) {
                    return track
                }
                return TrackInfo(uri: spec.fallbackTrackUri, title: "", artist: "")
            })
        case .opening, .ending:
            break
        }
    }

    private func resolveSpeaker(_ djId: String?, djs: [DjProfile], anchor: DjProfile) throws -> DjProfile {
        guard let djId else { return anchor }
        guard let dj = djs.first(where: { $0.id == djId }) else {
            throw ConfigError.missingField("segment の dj_id に未定義の DJ: \(djId)")
        }
        return dj
    }

    /// 時刻プレースホルダ + 番組コンテキスト（{first_song} 等）の展開。
    /// 発話直前に呼ぶことで時報として正確になる（仕様 s8 §3 / s10 §2）。
    private func expand(_ template: String, extra: [String: String]) -> String {
        var values = TimePhrases.values(date: clock.now, greetings: themes.greetings, timeZone: timeZone)
        values.merge(extra) { _, new in new }
        return TemplateExpander.expand(template, values: values)
    }
}

/// ローリング準備の台帳（仕様 s13 §3/§4）。準備 Task の保持・完了記録・破棄・一括キャンセルを
/// スレッドセーフに行う（準備 Task は並行に完了し、キャンセルは UI / onCancel から飛んでくる）。
private final class PreparationLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var cornerTasks: [Int: Task<PreparedCorner, any Error>] = [:]
    private var newsTasks: [Int: Task<String, Never>] = [:]
    private var songTasks: [Int: Task<TrackInfo, Never>] = [:]
    private var preparedCorners: Set<Int> = []

    func addCorner(at index: Int, _ task: Task<PreparedCorner, any Error>) {
        lock.withLock { cornerTasks[index] = task }
    }
    func addNews(at index: Int, _ task: Task<String, Never>) {
        lock.withLock { newsTasks[index] = task }
    }
    func addSong(at index: Int, _ task: Task<TrackInfo, Never>) {
        lock.withLock { songTasks[index] = task }
    }

    func cornerTask(at index: Int) -> Task<PreparedCorner, any Error>? {
        lock.withLock { cornerTasks[index] }
    }
    func newsTask(at index: Int) -> Task<String, Never>? {
        lock.withLock { newsTasks[index] }
    }
    func songTask(at index: Int) -> Task<TrackInfo, Never>? {
        lock.withLock { songTasks[index] }
    }

    func markCornerPrepared(at index: Int) {
        lock.withLock { _ = preparedCorners.insert(index) }
    }
    /// 準備が**完了済み**か（ED 判定用。実行中・未着手は false）。
    func isCornerPrepared(at index: Int) -> Bool {
        lock.withLock { preparedCorners.contains(index) }
    }

    /// 消費済みの準備を破棄する（ローリング窓の後端）。
    func discard(_ index: Int) {
        lock.withLock {
            cornerTasks.removeValue(forKey: index)
            newsTasks.removeValue(forKey: index)
            songTasks.removeValue(forKey: index)
            preparedCorners.remove(index)
        }
    }

    /// 保持中の準備をすべてキャンセルする（`keeping` だけ残す = ED の直後トーク）。
    func cancelAll(keeping kept: Int? = nil) {
        lock.withLock {
            for (index, task) in cornerTasks where index != kept { task.cancel() }
            for (index, task) in newsTasks where index != kept { task.cancel() }
            for (index, task) in songTasks where index != kept { task.cancel() }
        }
    }
}
