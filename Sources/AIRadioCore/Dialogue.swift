import Foundation

/// 番組 DJ のプロフィール（`config/djs.yaml`）。
public struct DjProfile: Sendable, Equatable {
    public var id: String
    public var name: String
    public var speakerId: Int
    public var persona: String

    public init(id: String, name: String, speakerId: Int, persona: String) {
        self.id = id
        self.name = name
        self.speakerId = speakerId
        self.persona = persona
    }
}

/// 会話台本の 1 行（どの DJ が何を喋るか）。
public struct DialogueLine: Sendable, Equatable {
    public var djId: String
    public var text: String

    public init(djId: String, text: String) {
        self.djId = djId
        self.text = text
    }
}

/// コーナー 1 本分の会話台本。
public struct DialogueScript: Sendable, Equatable {
    public var lines: [DialogueLine]

    public init(lines: [DialogueLine]) {
        self.lines = lines
    }

    /// セリフの合計文字数（長さ確認用）。
    public var totalCharacters: Int {
        lines.reduce(0) { $0 + $1.text.count }
    }
}

/// コーナーの進行フォーマット（仕様 s12 §2 / s14 / s15）。
public enum CornerFormat: String, Sendable, Equatable {
    /// テーマについて DJ 二人が会話し、最後に一曲かける（基本パターン）。
    case freeTalk = "free_talk"
    /// 架空リスナーのお便りを読み上げ → 感想 → リクエスト曲。
    case letter
    /// ゲストを迎えてテーマについて会話 → リクエスト曲（その日のテーマに詳しい専門家として登場、仕様 s14）。
    case guest
    /// アーティスト特集（1 組のアーティストの最大 7 曲を 3+3+1 で。専用エンジンで実行、仕様 s15）。
    case artistFeature = "artist_feature"
}

/// アーティスト特集（仕様 s15）のパート別目標文字数と締め文（`corners.yaml` の artist_feature コーナー）。
/// 既定値はハードコードせず YAML で上書き可。`commentShortTargetChars < commentTargetChars` をローダで検証する。
public struct ArtistFeatureParams: Sendable, Equatable {
    /// 導入（特集宣言＋アーティストへの思い一言）の目標文字数。
    public var introTargetChars: Int
    /// 各グループの曲紹介の目標文字数。
    public var groupIntroTargetChars: Int
    /// 1 回目の感想の目標文字数。
    public var commentTargetChars: Int
    /// 2 回目以降の感想の目標文字数（1 回目より短く）。
    public var commentShortTargetChars: Int
    /// 締めの固定文（LLM 生成しない。「アーティスト特集でした。」を含む）。
    public var outroLine: String

    public init(
        introTargetChars: Int = 200,
        groupIntroTargetChars: Int = 320,
        commentTargetChars: Int = 400,
        commentShortTargetChars: Int = 240,
        outroLine: String = "以上、アーティスト特集でした。"
    ) {
        self.introTargetChars = introTargetChars
        self.groupIntroTargetChars = groupIntroTargetChars
        self.commentTargetChars = commentTargetChars
        self.commentShortTargetChars = commentShortTargetChars
        self.outroLine = outroLine
    }
}

/// コーナー準備時に番組側（`BroadcastEngine`）から渡す実行コンテキスト（仕様 s13.5 §7）。
/// その日の編成・冒頭挨拶・時報リード文を台本／発話に反映するための情報。
public struct CornerContext: Sendable, Equatable {
    /// その日の出演者（順序付き・先頭＝メイン）。空なら `CornerTemplate.djIds` を使う。
    public var castDjIds: [String]
    /// 冒頭コーナーのみ非 nil（時刻連動の挨拶語）。非 nil＝挨拶＋出演者紹介、nil＝挨拶抑制で即本題。
    public var greeting: String?
    /// 本編前に読み上げる時報リード文テンプレート（時刻プレースホルダを含む、発話直前に展開）。
    /// nil／空なら頭出しなし（冒頭コーナーは nil）。
    public var leadIn: String?
    /// ゲストコーナーのとき、迎えるゲスト（cast 末尾に追加。仕様 s14）。nil＝ゲストなし。
    public var guest: DjProfile?

    public init(castDjIds: [String] = [], greeting: String? = nil, leadIn: String? = nil, guest: DjProfile? = nil) {
        self.castDjIds = castDjIds
        self.greeting = greeting
        self.leadIn = leadIn
        self.guest = guest
    }
}

/// コーナーのテンプレート（`config/corners.yaml`）。
/// 基本パターン: テーマについて DJ 二人が会話し、最後に一曲かける。
public struct CornerTemplate: Sendable, Equatable {
    public var id: String
    public var title: String
    public var theme: String
    /// テーマのプール。空でなければ準備のたびにランダムに 1 つ選ぶ（空なら `theme` 固定）。
    public var themePool: [String]
    public var format: CornerFormat
    public var djIds: [String]
    public var targetMinutes: Int
    public var charsPerMinute: Int
    public var songPromptHint: String
    public var fallbackTrackUri: String
    public var volume: Int
    /// 締めの曲を頭から何秒かけるか。0 = 曲の長さぶんフル再生。
    public var playSeconds: Int
    /// 本編前に読み上げる時報リード文テンプレート（時刻プレースホルダを含む。空＝頭出しなし。仕様 s13.5 §5）。
    /// 冒頭コーナーでは番組側が使わない（挨拶ダイアログが頭になるため）。
    public var leadIn: String
    /// アーティスト特集（format: artist_feature）のパラメータ。他フォーマットでは nil（仕様 s15）。
    public var artistFeatureParams: ArtistFeatureParams?

    public init(
        id: String,
        title: String,
        theme: String,
        themePool: [String] = [],
        format: CornerFormat = .freeTalk,
        djIds: [String],
        targetMinutes: Int = 5,
        charsPerMinute: Int = 320,
        songPromptHint: String = "",
        fallbackTrackUri: String,
        volume: Int = 85,
        playSeconds: Int = 0,
        leadIn: String = "",
        artistFeatureParams: ArtistFeatureParams? = nil
    ) {
        self.id = id
        self.title = title
        self.theme = theme
        self.themePool = themePool
        self.format = format
        self.djIds = djIds
        self.targetMinutes = targetMinutes
        self.charsPerMinute = charsPerMinute
        self.songPromptHint = songPromptHint
        self.fallbackTrackUri = fallbackTrackUri
        self.volume = volume
        self.playSeconds = playSeconds
        self.leadIn = leadIn
        self.artistFeatureParams = artistFeatureParams
    }

    /// 台本の目標文字数（5 分 × 320 字/分 ≒ 1600 字）。
    public var targetCharacters: Int {
        targetMinutes * charsPerMinute
    }
}
