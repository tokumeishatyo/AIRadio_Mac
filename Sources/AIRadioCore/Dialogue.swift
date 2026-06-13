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

/// コーナーの進行フォーマット（仕様 s12 §2）。
public enum CornerFormat: String, Sendable, Equatable {
    /// テーマについて DJ 二人が会話し、最後に一曲かける（基本パターン）。
    case freeTalk = "free_talk"
    /// 架空リスナーのお便りを読み上げ → 感想 → リクエスト曲。
    case letter
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

    public init(castDjIds: [String] = [], greeting: String? = nil, leadIn: String? = nil) {
        self.castDjIds = castDjIds
        self.greeting = greeting
        self.leadIn = leadIn
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
        leadIn: String = ""
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
    }

    /// 台本の目標文字数（5 分 × 320 字/分 ≒ 1600 字）。
    public var targetCharacters: Int {
        targetMinutes * charsPerMinute
    }
}
