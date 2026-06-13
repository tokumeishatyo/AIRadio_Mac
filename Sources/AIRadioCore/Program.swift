import Foundation

/// 番組セグメントの種類。部品が揃い次第 case を追加する（お便り・特集等）。
public enum SegmentKind: String, Sendable, Equatable, CaseIterable {
    case opening
    case song
    case talk
    case news
    /// アーティスト特集（仕様 s15）。talk とは曲数・進行が別物なので独立 case にする（意図的な非対称）。
    case artistFeature
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

/// 番組の長さ（仕様 s13 §2）。トークコーナーの本数で数える（お便り/ニュース/OP/冒頭曲/ED は含めない）。
public enum ProgramLength: Sendable, Equatable {
    case corners(Int)
    case endless

    /// UserDefaults / YAML 用の文字列表現（"10" / "endless"）。
    public init?(rawValue: String) {
        if rawValue == "endless" {
            self = .endless
        } else if let count = Int(rawValue), count >= 0 {
            self = .corners(count)
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .corners(let count): return String(count)
        case .endless: return "endless"
        }
    }
}

/// 番組の部品宣言（`config/program.yaml` v2）。セグメント列はここから決定論的に生成する（s13 §2/§6）。
public struct ProgramBlueprint: Sendable, Equatable {
    public var title: String
    /// opening / news / ending の読み上げを担当する DJ（djs.yaml の id）。
    public var anchorDjId: String
    /// メニュー「番組の長さ」の既定値。
    public var defaultLength: ProgramLength
    /// OP 失敗で放送を中止するか（既定 true、Windows 踏襲）。
    public var openingCritical: Bool
    /// 冒頭曲（OP 直後の 1 曲）。
    public var song: SongSegmentSpec
    /// トークコーナー（corners.yaml の id）。番組の長さ N はこのコーナーの本数。
    public var talkCornerId: String
    /// お便りコーナー（corners.yaml の id）。
    public var letterCornerId: String
    /// ニュースの読み上げ DJ（nil なら anchor）。
    public var newsDjId: String?
    /// 曜日替わり編成（メイン＝先頭。仕様 s13.5 §2）。
    public var weeklyCast: WeeklyCast
    /// ゲストコーナー（corners.yaml の id）。nil でゲストコーナー無効（仕様 s14 §3）。
    /// 設定すると最初の news の直後に 1 回だけゲスト talk が挿入される。
    public var guestCornerId: String?
    /// アーティスト特集（corners.yaml の id、format: artist_feature）。nil で無効（仕様 s15 §3）。
    /// 設定するとゲストコーナーの直後に 1 回だけ挿入される（ゲストに従属）。
    public var artistFeatureCornerId: String?

    public init(
        title: String,
        anchorDjId: String,
        defaultLength: ProgramLength = .corners(10),
        openingCritical: Bool = true,
        song: SongSegmentSpec,
        talkCornerId: String,
        letterCornerId: String,
        newsDjId: String? = nil,
        weeklyCast: WeeklyCast = .standard,
        guestCornerId: String? = nil,
        artistFeatureCornerId: String? = nil
    ) {
        self.title = title
        self.anchorDjId = anchorDjId
        self.defaultLength = defaultLength
        self.openingCritical = openingCritical
        self.song = song
        self.talkCornerId = talkCornerId
        self.letterCornerId = letterCornerId
        self.newsDjId = newsDjId
        self.weeklyCast = weeklyCast
        self.guestCornerId = guestCornerId
        self.artistFeatureCornerId = artistFeatureCornerId
    }
}

/// 曜日替わり編成（仕様 s13.5 §2）。Calendar の weekday（1=日…7=土）→ 順序付き DJ id（先頭＝メイン）。
/// メインが OP・ED・時報リード文・トークを仕切り、以降はサブ。完全決定論（テストは固定日付で検証）。
public struct WeeklyCast: Sendable, Equatable {
    public var casts: [Int: [String]]

    public init(casts: [Int: [String]]) {
        self.casts = casts
    }

    /// 指定日の編成（先頭＝メイン）。未定義の曜日は空配列。
    public func djIds(for date: Date, timeZone: TimeZone = .current) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return casts[calendar.component(.weekday, from: date)] ?? []
    }

    /// 指定日のメイン DJ（編成の先頭）。未定義なら nil。
    public func mainDjId(for date: Date, timeZone: TimeZone = .current) -> String? {
        djIds(for: date, timeZone: timeZone).first
    }

    /// 仕様の確定表（`weekly_cast` 省略時の既定）。weekday: 1=日 2=月 … 7=土。
    public static let standard = WeeklyCast(casts: [
        1: ["zundamon", "metan", "tsumugi"],  // 日: ずんメイン 3 人運営
        2: ["zundamon", "metan"],             // 月
        3: ["metan", "tsumugi"],              // 火
        4: ["tsumugi", "zundamon"],           // 水
        5: ["zundamon", "metan"],             // 木
        6: ["metan", "tsumugi"],              // 金
        7: ["tsumugi", "zundamon"],           // 土
    ])
}

/// コーナー数 N から決定論的に生成される番組（仕様 s13 §2）。
/// 構成: `opening → song → 本編 → ending`。本編はトーク 2 本ごとに「お便り → ニュース」を挿入
/// （= `talk, talk, letter, news` の繰り返し）。N 奇数の端数トークの後はお便りを挟まず ED へ。
/// エンドレスは本編を無限に繰り返し ED なし。
public struct ProgramPlan: Sendable, Equatable {
    public let blueprint: ProgramBlueprint
    public let length: ProgramLength

    public init(blueprint: ProgramBlueprint, length: ProgramLength) {
        self.blueprint = blueprint
        self.length = length
    }

    public var title: String { blueprint.title }
    public var anchorDjId: String { blueprint.anchorDjId }

    /// 総セグメント数（エンドレスは nil。UI の「n/全体」表示用）。ゲスト・特集があれば各 +1。
    public var totalSegmentCount: Int? {
        guard case .corners(let n) = length else { return nil }
        // OP + song + 本編（ペア×4 + 端数）+ ED（+ ゲスト 1 + 特集 1）
        return 2 + (n / 2) * 4 + (n % 2) + 1 + (includesGuestCorner ? 1 : 0) + (includesArtistFeature ? 1 : 0)
    }

    /// この番組がゲストコーナーを実際に含むか（guestCornerId 設定 かつ 最初の news が存在＝N≥2 / エンドレス。仕様 s14 §3）。
    /// 番組側はこれを見て「ゲストが出る放送のときだけ」ゲスト検証・選定を行う（N<2 で誤って中止しないため）。
    public var includesGuestCorner: Bool {
        guard blueprint.guestCornerId != nil else { return false }
        switch length {
        case .endless: return true
        case .corners(let n): return n >= 2
        }
    }

    /// この番組がアーティスト特集を実際に含むか（artistFeatureCornerId 設定 かつ ゲストコーナーが入る＝従属。仕様 s15 §3）。
    public var includesArtistFeature: Bool {
        blueprint.artistFeatureCornerId != nil && includesGuestCorner
    }

    /// ゲスト talk が入る body 位置（最初の news の次 = body 4）。挿入しないなら nil。
    private var guestBodyPosition: Int? { includesGuestCorner ? 4 : nil }

    /// アーティスト特集が入る body 位置（ゲストの次 = body 5）。挿入しないなら nil。
    private var artistFeatureBodyPosition: Int? { includesArtistFeature ? 5 : nil }

    /// body 位置より手前にある割り込み（ゲスト・特集）の個数。素のパターン参照の補正に使う（仕様 s15 §3-3）。
    private func insertionsBefore(_ body: Int) -> Int {
        [guestBodyPosition, artistFeatureBodyPosition].compactMap { $0 }.filter { $0 < body }.count
    }

    /// index 番目のセグメント（0 始まり）。有限番組は ED の次で nil、エンドレスは常に非 nil。
    public func segment(at index: Int) -> ProgramSegment? {
        switch index {
        case ..<0:
            return nil
        case 0:
            return ProgramSegment(kind: .opening, critical: blueprint.openingCritical)
        case 1:
            return ProgramSegment(kind: .song, song: blueprint.song)
        default:
            return bodySegment(at: index - 2)
        }
    }

    /// 本編 body の index → セグメント。割り込み（ゲスト body4・特集 body5）を順に差し込み、
    /// それ以外は「割り込みを除いた素 body」でパターンを参照する（`insertionsBefore` に一本化、仕様 s15 §3-3）。
    private func bodySegment(at body: Int) -> ProgramSegment? {
        if let guestPos = guestBodyPosition, body == guestPos {
            return ProgramSegment(kind: .talk, cornerId: blueprint.guestCornerId)
        }
        if let featurePos = artistFeatureBodyPosition, body == featurePos {
            return ProgramSegment(kind: .artistFeature, cornerId: blueprint.artistFeatureCornerId, critical: false)
        }
        return patternBodySegment(at: body - insertionsBefore(body))
    }

    /// ゲスト挿入を考慮しない素の本編 body（`talk, talk, letter, news` の繰り返し + 端数 + ED）。
    private func patternBodySegment(at body: Int) -> ProgramSegment? {
        switch length {
        case .endless:
            return patternSegment(at: body % 4)
        case .corners(let n):
            let pairBody = (n / 2) * 4
            let remainder = n % 2
            if body < pairBody {
                return patternSegment(at: body % 4)
            }
            if remainder == 1 && body == pairBody {
                return ProgramSegment(kind: .talk, cornerId: blueprint.talkCornerId)
            }
            if body == pairBody + remainder {
                return ProgramSegment(kind: .ending)
            }
            return nil
        }
    }

    /// 本編パターン `talk, talk, letter, news` の 1 要素。
    private func patternSegment(at position: Int) -> ProgramSegment {
        switch position {
        case 0, 1:
            return ProgramSegment(kind: .talk, cornerId: blueprint.talkCornerId)
        case 2:
            return ProgramSegment(kind: .talk, cornerId: blueprint.letterCornerId)
        default:
            return ProgramSegment(kind: .news, djId: blueprint.newsDjId)
        }
    }
}

/// 放送中の操作（UI スレッドから安全に呼べる。仕様 s13 §4）。
public final class BroadcastControl: @unchecked Sendable {
    private let lock = NSLock()
    private var ending = false

    public init() {}

    /// 「ED で終了」要求。現在のセグメント（+ 準備済みの直後トーク）を流したら ED で締める。
    public func requestEnding() {
        lock.withLock { ending = true }
    }

    public var isEndingRequested: Bool {
        lock.withLock { ending }
    }
}

/// DJ 別の固定口上（OP / ED。口調込み・YAML 由来で不変。仕様 s13.5 §4）。
public struct DjSpiel: Sendable, Equatable {
    /// BGM 前の一言（OP のみ。ED は nil）。
    public var tagline: String?
    /// 本文（時刻プレースホルダ `{greeting}` 等を含み、発話直前に展開される）。
    public var announcement: String

    public init(tagline: String? = nil, announcement: String) {
        self.tagline = tagline
        self.announcement = announcement
    }
}

/// テーマ系セグメント（OP / ED）。BGM 演出は共有、口上は DJ 別（その日のメインのものを使う）。
public struct ThemedSegment: Sendable, Equatable {
    /// 共有 BGM 演出（`staging.tagline` は無視。発話直前にメインの tagline を載せる）。
    public var staging: ThemeConfig
    /// dj id → 固定口上。
    public var byDj: [String: DjSpiel]

    public init(staging: ThemeConfig, byDj: [String: DjSpiel]) {
        self.staging = staging
        self.byDj = byDj
    }

    /// メインを優先し、無ければ fallbacks の順、それも無ければ任意の 1 件を返す。
    public func spiel(preferring djId: String, fallbacks: [String] = []) -> DjSpiel? {
        if let spiel = byDj[djId] { return spiel }
        for fallback in fallbacks {
            if let spiel = byDj[fallback] { return spiel }
        }
        return byDj.values.first
    }
}

/// 放送で使うテーマ一式。news の原稿は実行時に `AnnouncementProviding` が生成するため演出設定のみ。
public struct BroadcastThemes: Sendable, Equatable {
    public var opening: ThemedSegment
    public var news: ThemeConfig
    public var ending: ThemedSegment
    /// 時間帯挨拶（`{greeting}` プレースホルダの値、themes.yaml の `greetings:`）。
    public var greetings: Greetings

    public init(
        opening: ThemedSegment,
        news: ThemeConfig,
        ending: ThemedSegment,
        greetings: Greetings = Greetings()
    ) {
        self.opening = opening
        self.news = news
        self.ending = ending
        self.greetings = greetings
    }
}
