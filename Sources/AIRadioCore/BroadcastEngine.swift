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
    private let onEvent: (@Sendable (BroadcastEvent) -> Void)?

    public init(
        themes: BroadcastThemes,
        themeSequencer: any ThemeSequencing,
        cornerRunner: any CornerRunning,
        newsProvider: any AnnouncementProviding,
        spotify: any SpotifyController,
        onEvent: (@Sendable (BroadcastEvent) -> Void)? = nil
    ) {
        self.themes = themes
        self.themeSequencer = themeSequencer
        self.cornerRunner = cornerRunner
        self.newsProvider = newsProvider
        self.spotify = spotify
        self.onEvent = onEvent
    }

    public func run(program: Program, corners: [CornerTemplate], djs: [DjProfile]) async throws {
        // fail-fast 検証（音を出す前に設定不整合を弾く）。
        guard let anchor = djs.first(where: { $0.id == program.anchorDjId }) else {
            throw ConfigError.missingField("program.anchor_dj_id に未定義の DJ: \(program.anchorDjId)")
        }
        let resolved: [(segment: ProgramSegment, corner: CornerTemplate?)] = try program.segments.map { segment in
            guard segment.kind == .talk else { return (segment, nil) }
            guard let id = segment.cornerId, let corner = corners.first(where: { $0.id == id }) else {
                throw ConfigError.missingField("program.segments[].corner_id に未定義のコーナー: \(segment.cornerId ?? "(なし)")")
            }
            return (segment, corner)
        }

        do {
            for (index, entry) in resolved.enumerated() {
                try Task.checkCancellation()
                onEvent?(.segmentStarted(index: index, kind: entry.segment.kind))
                do {
                    try await perform(entry.segment.kind, corner: entry.corner, anchor: anchor, djs: djs)
                    onEvent?(.segmentFinished(index: index, kind: entry.segment.kind))
                } catch {
                    // キャンセル中は Infra 層が URLSession の取消をドメインエラーにラップして
                    // 投げてくることがある（例: E-SPT-AUTH-FAILED）。スキップと誤判定せず即時停止する。
                    if error is CancellationError || Task.isCancelled {
                        throw CancellationError()
                    }
                    // スキップして放送継続（fail-tolerant、E-RTM-SEGMENT-FAILED-001）。
                    let radioError = error as? RadioError
                    onEvent?(.segmentFailed(
                        index: index,
                        kind: entry.segment.kind,
                        code: radioError?.code ?? String(describing: type(of: error)),
                        detail: radioError?.message ?? String(describing: error)
                    ))
                }
            }
        } catch {
            try? await spotify.pause()
            throw error
        }
        // 各セグメントも自前で pause するが、エンジンでも重ねて完全静寂を保証する。
        try? await spotify.pause()
        onEvent?(.broadcastFinished)
    }

    private func perform(
        _ kind: SegmentKind,
        corner: CornerTemplate?,
        anchor: DjProfile,
        djs: [DjProfile]
    ) async throws {
        switch kind {
        case .opening:
            try await themeSequencer.run(
                theme: themes.opening.theme,
                announcement: themes.opening.announcement,
                speakerId: anchor.speakerId
            )
        case .talk:
            // resolved 済みなので corner は必ず存在する。
            try await cornerRunner.run(corner: corner!, djs: djs)
        case .news:
            let script = await newsProvider.announcement()
            try await themeSequencer.run(
                theme: themes.news,
                announcement: script,
                speakerId: anchor.speakerId
            )
        case .ending:
            try await themeSequencer.run(
                theme: themes.ending.theme,
                announcement: themes.ending.announcement,
                speakerId: anchor.speakerId
            )
        }
    }
}
