import Foundation

/// 放送進行中の出来事（デモ表示・ログ用）。
public enum BroadcastEvent: Sendable, Equatable {
    case segmentStarted(index: Int, kind: SegmentKind)
    case segmentFinished(index: Int, kind: SegmentKind)
    /// セグメント失敗（スキップして継続）。code / detail は基となったエラーのコードと詳細。
    case segmentFailed(index: Int, kind: SegmentKind, code: String, detail: String)
    case broadcastFinished
}

/// 番組フォーマット（`Program`）に従ってセグメントを順次実行する放送エンジン。
/// - fail-tolerant: セグメント失敗は `segmentFailed` を通知して次へ（放送継続）。
/// - キャンセル（`Task.cancel()`）は即時伝播し、後続セグメントは実行しない。
/// - 正常・失敗・キャンセルのいずれでも最後は必ず `pause()`（完全静寂、CLAUDE.md §3-1）。
public struct BroadcastEngine: Sendable {
    private let themes: BroadcastThemes
    private let themeSequencer: any ThemeSequencing
    private let cornerRunner: any CornerRunning
    private let newsProvider: any AnnouncementProviding
    private let spotify: any SpotifyController
    private let clock: any Clock
    private let timeZone: TimeZone
    private let onEvent: (@Sendable (BroadcastEvent) -> Void)?

    public init(
        themes: BroadcastThemes,
        themeSequencer: any ThemeSequencing,
        cornerRunner: any CornerRunning,
        newsProvider: any AnnouncementProviding,
        spotify: any SpotifyController,
        clock: any Clock,
        timeZone: TimeZone = .current,
        onEvent: (@Sendable (BroadcastEvent) -> Void)? = nil
    ) {
        self.themes = themes
        self.themeSequencer = themeSequencer
        self.cornerRunner = cornerRunner
        self.newsProvider = newsProvider
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
                guard segment.kind == .talk else { return (segment, nil, speaker.speakerId) }
                guard let id = segment.cornerId, let corner = corners.first(where: { $0.id == id }) else {
                    throw ConfigError.missingField("program.segments[].corner_id に未定義のコーナー: \(segment.cornerId ?? "(なし)")")
                }
                return (segment, corner, speaker.speakerId)
            }

        do {
            for (index, entry) in resolved.enumerated() {
                try Task.checkCancellation()
                onEvent?(.segmentStarted(index: index, kind: entry.segment.kind))
                do {
                    try await perform(entry.segment.kind, corner: entry.corner, speakerId: entry.speakerId, djs: djs)
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
    }

    private func perform(
        _ kind: SegmentKind,
        corner: CornerTemplate?,
        speakerId: Int,
        djs: [DjProfile]
    ) async throws {
        switch kind {
        case .opening:
            try await themeSequencer.run(
                theme: themes.opening.theme,
                announcement: expandTime(themes.opening.announcement),
                speakerId: speakerId
            )
        case .talk:
            // resolved 済みなので corner は必ず存在する。
            try await cornerRunner.run(corner: corner!, djs: djs)
        case .news:
            // Provider が {news}/{weather} を展開した原稿に、発話直前の時刻を二段展開する。
            let script = await newsProvider.announcement()
            try await themeSequencer.run(
                theme: themes.news,
                announcement: expandTime(script),
                speakerId: speakerId
            )
        case .ending:
            try await themeSequencer.run(
                theme: themes.ending.theme,
                announcement: expandTime(themes.ending.announcement),
                speakerId: speakerId
            )
        }
    }

    /// 時刻プレースホルダの展開（発話直前に呼ぶことで時報として正確になる、仕様 s8 §3）。
    private func expandTime(_ template: String) -> String {
        TemplateExpander.expand(
            template,
            values: TimePhrases.values(date: clock.now, greetings: themes.greetings, timeZone: timeZone)
        )
    }
}
