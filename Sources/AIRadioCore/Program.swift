import Foundation

/// 番組セグメントの種類。部品が揃い次第 case を追加する（お便り・特集等）。
public enum SegmentKind: String, Sendable, Equatable, CaseIterable {
    case opening
    case song
    case talk
    case news
    case ending
}

/// `song` セグメント（冒頭曲など、トークなしの 1 曲）の設定。
public struct SongSegmentSpec: Sendable, Equatable {
    /// 選曲プロンプトのヒント（例: 「番組の幕開けに合う、前向きで広く知られた曲」）。
    public var promptHint: String
    public var fallbackTrackUri: String
    public var volume: Int
    /// 頭から何秒かけるか。0 = フル再生。
    public var playSeconds: Int

    public init(promptHint: String = "", fallbackTrackUri: String, volume: Int = 100, playSeconds: Int = 0) {
        self.promptHint = promptHint
        self.fallbackTrackUri = fallbackTrackUri
        self.volume = volume
        self.playSeconds = playSeconds
    }
}

/// 番組フォーマットの 1 セグメント（`config/program.yaml`）。
public struct ProgramSegment: Sendable, Equatable {
    public var kind: SegmentKind
    /// `talk` のときのみ必須（corners.yaml の id を参照）。
    public var cornerId: String?
    /// true なら失敗時にスキップせず放送を中止する（Windows 版踏襲。既定の番組では OP に設定）。
    public var critical: Bool
    /// テーマ系セグメント（opening / news / ending）の読み上げ DJ。nil なら `anchor_dj_id`。
    public var djId: String?
    /// `song` のときのみ必須。
    public var song: SongSegmentSpec?

    public init(
        kind: SegmentKind,
        cornerId: String? = nil,
        critical: Bool = false,
        djId: String? = nil,
        song: SongSegmentSpec? = nil
    ) {
        self.kind = kind
        self.cornerId = cornerId
        self.critical = critical
        self.djId = djId
        self.song = song
    }
}

/// 番組フォーマット全体。
public struct Program: Sendable, Equatable {
    public var title: String
    /// opening / news / ending の読み上げを担当する DJ（djs.yaml の id）。
    public var anchorDjId: String
    public var segments: [ProgramSegment]

    public init(title: String, anchorDjId: String, segments: [ProgramSegment]) {
        self.title = title
        self.anchorDjId = anchorDjId
        self.segments = segments
    }
}

/// テーマ演出 + 固定の発話文（opening / ending 用）。
public struct ThemedAnnouncement: Sendable, Equatable {
    public var theme: ThemeConfig
    public var announcement: String

    public init(theme: ThemeConfig, announcement: String) {
        self.theme = theme
        self.announcement = announcement
    }
}

/// 放送で使うテーマ一式。news の原稿は実行時に `AnnouncementProviding` が生成するため演出設定のみ。
public struct BroadcastThemes: Sendable, Equatable {
    public var opening: ThemedAnnouncement
    public var news: ThemeConfig
    public var ending: ThemedAnnouncement
    /// 時間帯挨拶（`{greeting}` プレースホルダの値、themes.yaml の `greetings:`）。
    public var greetings: Greetings

    public init(
        opening: ThemedAnnouncement,
        news: ThemeConfig,
        ending: ThemedAnnouncement,
        greetings: Greetings = Greetings()
    ) {
        self.opening = opening
        self.news = news
        self.ending = ending
        self.greetings = greetings
    }
}
