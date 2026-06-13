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
    /// アーティスト特集の実行（仕様 s15）。特集コーナー有効時は必須（未配線なら fail-fast）。
    private let artistFeatureRunner: (any ArtistFeatureRunning)?
    private let newsProvider: any AnnouncementProviding
    private let songPicker: (any SongPicking)?
    private let spotify: any SpotifyController
    private let clock: any Clock
    private let timeZone: TimeZone
    /// ゲスト・特集アーティスト選定用の乱数（0..<count のインデックス。テストは決定論的に注入。仕様 s14/s15）。
    private let randomIndex: @Sendable (Int) -> Int
    private let onEvent: (@Sendable (BroadcastEvent) -> Void)?

    public init(
        themes: BroadcastThemes,
        themeSequencer: any ThemeSequencing,
        cornerRunner: any CornerRunning,
        artistFeatureRunner: (any ArtistFeatureRunning)? = nil,
        newsProvider: any AnnouncementProviding,
        songPicker: (any SongPicking)? = nil,
        spotify: any SpotifyController,
        clock: any Clock,
        timeZone: TimeZone = .current,
        randomIndex: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<$0) },
        onEvent: (@Sendable (BroadcastEvent) -> Void)? = nil
    ) {
        self.themes = themes
        self.themeSequencer = themeSequencer
        self.cornerRunner = cornerRunner
        self.artistFeatureRunner = artistFeatureRunner
        self.newsProvider = newsProvider
        self.songPicker = songPicker
        self.spotify = spotify
        self.clock = clock
        self.timeZone = timeZone
        self.randomIndex = randomIndex
        self.onEvent = onEvent
    }

    public func run(
        plan: ProgramPlan,
        corners: [CornerTemplate],
        djs: [DjProfile],
        guests: [DjProfile] = [],
        artists: [ArtistProfile] = [],
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
        // ゲストコーナー検証＋選定（仕様 s14）。実際にゲスト枠が出る放送のときだけ行う
        // （N<2 等でゲストが出ないなら、プール空でも誤って放送中止しない）。
        var selectedGuest: DjProfile?
        if let guestCornerId = plan.blueprint.guestCornerId, plan.includesGuestCorner {
            guard corners.contains(where: { $0.id == guestCornerId }) else {
                throw ConfigError.missingField("program.guest.corner_id に未定義のコーナー: \(guestCornerId)")
            }
            // ゲストコーナー id はトーク／お便りと別物でなければならない（同じだと全トークがゲスト化する）。
            guard guestCornerId != plan.blueprint.talkCornerId, guestCornerId != plan.blueprint.letterCornerId else {
                throw ConfigError.missingField("program.guest.corner_id が talk/letter と重複: \(guestCornerId)")
            }
            guard !guests.isEmpty else {
                throw ConfigError.missingField("guests: ゲストプールが空です（ゲストコーナー有効時は必須）")
            }
            if let collision = guests.first(where: { guest in djs.contains { $0.id == guest.id } }) {
                throw ConfigError.missingField("guests にレギュラーと衝突する id: \(collision.id)")
            }
            selectedGuest = guests[randomIndex(guests.count)]
        }
        // アーティスト特集の検証＋選定（仕様 s15）。特集が出る放送（ゲスト従属）のときだけ行う。
        // プールが空でも fail-fast にしない（空ならスキップ。仕様 s15 §8-4）。壊れた設定のみ fail-fast。
        var selectedArtist: ArtistProfile?
        if let featureCornerId = plan.blueprint.artistFeatureCornerId, plan.includesArtistFeature {
            guard corners.contains(where: { $0.id == featureCornerId }) else {
                throw ConfigError.missingField("program.artist_feature.corner_id に未定義のコーナー: \(featureCornerId)")
            }
            guard featureCornerId != plan.blueprint.talkCornerId,
                  featureCornerId != plan.blueprint.letterCornerId,
                  featureCornerId != plan.blueprint.guestCornerId else {
                throw ConfigError.missingField("program.artist_feature.corner_id が talk/letter/guest と重複: \(featureCornerId)")
            }
            guard artistFeatureRunner != nil else {
                throw ConfigError.missingField("artistFeatureRunner が未配線です（アーティスト特集有効時は必須）")
            }
            if !artists.isEmpty {
                selectedArtist = artists[randomIndex(artists.count)]
            }
        }
        // その日の編成（先頭＝メイン）を解決（仕様 s13.5 §2）。空・未定義 id は fail-fast。
        let castDjIds = plan.blueprint.weeklyCast.djIds(for: clock.now, timeZone: timeZone)
        guard !castDjIds.isEmpty else {
            throw ConfigError.missingField("weekly_cast: 本日（曜日）の編成が定義されていません")
        }
        let cast = try castDjIds.map { id -> DjProfile in
            guard let dj = djs.first(where: { $0.id == id }) else {
                throw ConfigError.missingField("weekly_cast に未定義の DJ: \(id)")
            }
            return dj
        }
        let main = cast[0]

        // 準備 Task はエンジンのキャンセルを継承しない（非構造化）ため、停止時に明示キャンセルする。
        let ledger = PreparationLedger()
        try await withTaskCancellationHandler {
            defer { ledger.cancelAll() }
            try await broadcast(
                plan: plan, corners: corners, djs: djs,
                cast: cast, main: main, anchor: anchor, guest: selectedGuest, artist: selectedArtist,
                control: control, ledger: ledger)
        } onCancel: {
            ledger.cancelAll()
        }
    }

    // MARK: - 放送本体

    private func broadcast(
        plan: ProgramPlan,
        corners: [CornerTemplate],
        djs: [DjProfile],
        cast: [DjProfile],
        main: DjProfile,
        anchor: DjProfile,
        guest: DjProfile?,
        artist: ArtistProfile?,
        control: BroadcastControl?,
        ledger: PreparationLedger
    ) async throws {
        let castDjIds = cast.map(\.id)
        // 冒頭挨拶を付ける「番組最初のトーク」セグメント index（通常 2）。N=0 等で無ければ nil。
        let firstTalkIndex = Self.firstTalkIndex(in: plan)
        // 冒頭コーナーの時刻連動の挨拶語（準備時点で解決。再生まで数分なので時間帯ズレはほぼ無い）。
        let greeting = TimePhrases.values(date: clock.now, greetings: themes.greetings, timeZone: timeZone)["greeting"]

        // ローリング準備の起動（単一消費者なので進捗はローカル変数で追う）。
        var preparationStartedThrough = -1
        func ensurePrepared(through target: Int) {
            while preparationStartedThrough < target {
                preparationStartedThrough += 1
                let index = preparationStartedThrough
                guard let segment = plan.segment(at: index) else { return }
                let context = cornerContext(
                    for: segment, at: index, corners: corners,
                    castDjIds: castDjIds, firstTalkIndex: firstTalkIndex, greeting: greeting,
                    guestCornerId: plan.blueprint.guestCornerId, guest: guest)
                startPreparation(of: segment, at: index, plan: plan, corners: corners, djs: djs, context: context, artist: artist, ledger: ledger)
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
                try await runSegment(segment, at: index, djs: djs, cast: cast, main: main, anchor: anchor, extraValues: extraValues, ledger: ledger)
                ledger.discard(index)

                // 「ED で終了」: 直後のトーク（free_talk）が準備完了済みならそれだけ流し、
                // 残り（お便り / ニュース含む）はすべて飛ばして ED（仕様 s13 §4）。
                if let control, control.isEndingRequested, segment.kind != .ending {
                    onEvent?(.endingRequested)
                    var edIndex = index + 1
                    // 特集の直後は素の talk が続くが、特集を流し切ったら ED へ直行（余分なトークを挟まない、仕様 s15 §8-5）。
                    if segment.kind != .artistFeature,
                       let next = plan.segment(at: edIndex),
                       next.kind == .talk,
                       next.cornerId == plan.blueprint.talkCornerId,
                       ledger.isCornerPrepared(at: edIndex) {
                        ledger.cancelAll(keeping: edIndex)   // 窓の外を捨てる
                        try await runSegment(next, at: edIndex, djs: djs, cast: cast, main: main, anchor: anchor, extraValues: extraValues, ledger: ledger)
                        ledger.discard(edIndex)
                        edIndex += 1
                    } else {
                        ledger.cancelAll()
                    }
                    // ED を流して終了（エンドレスは plan に ED がないため合成。有限も前倒しで同じ）。
                    try await runSegment(
                        ProgramSegment(kind: .ending), at: edIndex,
                        djs: djs, cast: cast, main: main, anchor: anchor, extraValues: extraValues, ledger: ledger)
                    break
                }
                index += 1
            }
        } catch {
            await spotify.pauseIgnoringCancellation(restoringVolume: themes.opening.staging.volume)
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
        cast: [DjProfile],
        main: DjProfile,
        anchor: DjProfile,
        extraValues: [String: String],
        ledger: PreparationLedger
    ) async throws {
        onEvent?(.segmentStarted(index: index, kind: segment.kind))
        do {
            try await perform(segment, at: index, djs: djs, cast: cast, main: main, anchor: anchor, extraValues: extraValues, ledger: ledger)
            onEvent?(.segmentFinished(index: index, kind: segment.kind))
        } catch {
            // キャンセル中は Infra 層が URLSession の取消をドメインエラーにラップして
            // 投げてくることがある（例: E-SPT-AUTH-FAILED）。スキップと誤判定せず即時停止する。
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            // 失敗したセグメントが音を出したまま次へ進まないよう、ここでも静寂を保証する。
            await spotify.pauseIgnoringCancellation(restoringVolume: themes.opening.staging.volume)
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
        cast: [DjProfile],
        main: DjProfile,
        anchor: DjProfile,
        extraValues: [String: String],
        ledger: PreparationLedger
    ) async throws {
        switch segment.kind {
        case .opening:
            // OP はその日のメインが読み、メインの口上を使う。無ければ anchor → 先頭の順（仕様 s13.5 §4）。
            let spiel = themes.opening.spiel(preferring: main.id, fallbacks: [anchor.id]) ?? DjSpiel(announcement: "")
            var staging = themes.opening.staging
            staging.tagline = spiel.tagline
            try await themeSequencer.run(
                theme: staging,
                announcement: expand(spiel.announcement, extra: extraValues),
                speakerId: main.speakerId
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
        case .artistFeature:
            // 先行準備（窓内に完了済み）を取り出して実行。skipped（プール空 / 曲不足）なら
            // run が featureSkipped を出して何も流さない（仕様 s15 §8-4）。
            guard let task = ledger.artistFeatureTask(at: index) else {
                throw BroadcastError.segmentFailed("artist_feature: 準備タスクがありません（index \(index)）")
            }
            let prepared = try await task.value
            guard let runner = artistFeatureRunner else {
                throw BroadcastError.segmentFailed("artist_feature: ランナー未配線（index \(index)）")
            }
            try await runner.run(prepared: prepared, djs: djs)
        case .news:
            // 原稿は出現のたびに先行準備で生成（長時間放送でニュースが更新される、s13 §3）。
            // 読み手は専任（program.news.dj_id＝龍星。曜日替わりの影響を受けない）。
            // 未指定はアンカー固定（原稿のペルソナも anchor 基準。メイン交代の影響を受けない）。
            let newsSpeaker = try resolveSpeaker(segment.djId, djs: djs, fallback: anchor)
            guard let script = await ledger.newsTask(at: index)?.value else {
                throw BroadcastError.segmentFailed("news: 準備タスクがありません（index \(index)）")
            }
            try await themeSequencer.run(
                theme: themes.news,
                announcement: expand(script, extra: extraValues),
                speakerId: newsSpeaker.speakerId
            )
        case .ending:
            // ED はその日のメインが読み、メインの口上を使う（タグラインなし）。無ければ anchor → 先頭。
            let spiel = themes.ending.spiel(preferring: main.id, fallbacks: [anchor.id]) ?? DjSpiel(announcement: "")
            var staging = themes.ending.staging
            staging.tagline = spiel.tagline
            try await themeSequencer.run(
                theme: staging,
                announcement: expand(spiel.announcement, extra: extraValues),
                speakerId: main.speakerId
            )
        }
    }

    private func startPreparation(
        of segment: ProgramSegment,
        at index: Int,
        plan: ProgramPlan,
        corners: [CornerTemplate],
        djs: [DjProfile],
        context: CornerContext,
        artist: ArtistProfile?,
        ledger: PreparationLedger
    ) {
        switch segment.kind {
        case .talk:
            // corner は fail-fast 検証済み（talk/letter とも実在する）。
            let corner = corners.first { $0.id == segment.cornerId }!
            let runner = cornerRunner
            ledger.addCorner(at: index, Task {
                let prepared = try await runner.prepare(corner: corner, djs: djs, context: context)
                ledger.markCornerPrepared(at: index)
                return prepared
            })
        case .artistFeature:
            // 特集の準備（top-tracks + 台本 + 事前合成）。直前の長いゲスト talk が緩衝になり窓内に間に合う（仕様 s15 §8-3）。
            // corner / runner は fail-fast 検証済み。プール空のときは artist=nil でスキップ準備物になる。
            let corner = corners.first { $0.id == segment.cornerId }!
            let runner = artistFeatureRunner
            let selectedArtist = artist
            let castDjIds = context.castDjIds
            let leadIn = context.leadIn
            ledger.addArtistFeature(at: index, Task {
                guard let runner else {
                    throw ConfigError.missingField("artistFeatureRunner が未配線です")
                }
                return try await runner.prepare(
                    corner: corner, artist: selectedArtist, djs: djs, castDjIds: castDjIds, leadIn: leadIn)
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

    private func resolveSpeaker(_ djId: String?, djs: [DjProfile], fallback: DjProfile) throws -> DjProfile {
        guard let djId else { return fallback }
        guard let dj = djs.first(where: { $0.id == djId }) else {
            throw ConfigError.missingField("segment の dj_id に未定義の DJ: \(djId)")
        }
        return dj
    }

    /// 番組内で最初の talk セグメントの index（冒頭挨拶を付ける対象。通常 2。無ければ nil）。
    private static func firstTalkIndex(in plan: ProgramPlan) -> Int? {
        var index = 0
        while let segment = plan.segment(at: index) {
            if segment.kind == .talk { return index }
            index += 1
            if index > 8 { break }   // 安全弁: 冒頭付近にあるはず（無ければ talk なし番組）
        }
        return nil
    }

    /// talk セグメントの準備に渡すコンテキスト（その日の編成・冒頭挨拶 or 時報リード文）。
    private func cornerContext(
        for segment: ProgramSegment,
        at index: Int,
        corners: [CornerTemplate],
        castDjIds: [String],
        firstTalkIndex: Int?,
        greeting: String?,
        guestCornerId: String?,
        guest: DjProfile?
    ) -> CornerContext {
        // アーティスト特集（仕様 s15）: その日の編成＋コーナーのリード文（{artist}/時刻は特集側で展開）。
        if segment.kind == .artistFeature {
            let leadIn = corners.first { $0.id == segment.cornerId }?.leadIn
            return CornerContext(castDjIds: castDjIds, greeting: nil, leadIn: leadIn)
        }
        guard segment.kind == .talk else { return CornerContext() }
        // ゲストコーナー（最初の news 直後に挿入された talk）: ゲストを cast 末尾に、リード文付き（仕様 s14）。
        if let guestCornerId, segment.cornerId == guestCornerId {
            let leadIn = corners.first { $0.id == segment.cornerId }?.leadIn
            return CornerContext(castDjIds: castDjIds, greeting: nil, leadIn: leadIn, guest: guest)
        }
        if index == firstTalkIndex {
            // 冒頭コーナー: 時刻連動の挨拶＋出演者紹介。リード文なし。
            return CornerContext(castDjIds: castDjIds, greeting: greeting, leadIn: nil)
        }
        // その他: 挨拶抑制で即本題。コーナー定義の時報リード文を頭に付ける。
        let leadIn = corners.first { $0.id == segment.cornerId }?.leadIn
        return CornerContext(castDjIds: castDjIds, greeting: nil, leadIn: leadIn)
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
    private var artistFeatureTasks: [Int: Task<PreparedArtistFeature, any Error>] = [:]
    private var newsTasks: [Int: Task<String, Never>] = [:]
    private var songTasks: [Int: Task<TrackInfo, Never>] = [:]
    private var preparedCorners: Set<Int> = []

    func addCorner(at index: Int, _ task: Task<PreparedCorner, any Error>) {
        lock.withLock { cornerTasks[index] = task }
    }
    func addArtistFeature(at index: Int, _ task: Task<PreparedArtistFeature, any Error>) {
        lock.withLock { artistFeatureTasks[index] = task }
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
    func artistFeatureTask(at index: Int) -> Task<PreparedArtistFeature, any Error>? {
        lock.withLock { artistFeatureTasks[index] }
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
            artistFeatureTasks.removeValue(forKey: index)
            newsTasks.removeValue(forKey: index)
            songTasks.removeValue(forKey: index)
            preparedCorners.remove(index)
        }
    }

    /// 保持中の準備をすべてキャンセルする（`keeping` だけ残す = ED の直後トーク）。
    func cancelAll(keeping kept: Int? = nil) {
        lock.withLock {
            for (index, task) in cornerTasks where index != kept { task.cancel() }
            for (index, task) in artistFeatureTasks where index != kept { task.cancel() }
            for (index, task) in newsTasks where index != kept { task.cancel() }
            for (index, task) in songTasks where index != kept { task.cancel() }
        }
    }
}
