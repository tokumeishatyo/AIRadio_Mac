import Foundation

/// ジャーナル 1 エントリ（1 放送分のハイライト。仕様 s18 §2）。
public struct JournalEntry: Sendable, Equatable {
    public var date: String        // "YYYY-MM-DD"
    public var highlight: String

    public init(date: String, highlight: String) {
        self.date = date
        self.highlight = highlight
    }
}

/// ステーション・ジャーナル（週次リセットの長期記憶。仕様 s18）。
/// `weekKey`（ISO 週・月曜始まり）で同一週を判定し、週が替われば過去を忘れる。
public struct StationJournal: Sendable, Equatable {
    public var weekKey: String
    public var entries: [JournalEntry]

    /// 週内に保持する最大エントリ数（1 日 1 放送想定。超えたら古い順に落とす）。
    public static let maxEntries = 7

    public init(weekKey: String = "", entries: [JournalEntry] = []) {
        self.weekKey = weekKey
        self.entries = entries
    }

    public static let empty = StationJournal()

    /// ISO 週（月曜始まり）のキー "YYYY-Www"（例 "2026-W24"）。週の同一判定に使う。
    public static func weekKey(now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .iso8601)   // firstWeekday=月, ISO 週
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }

    /// 現在週と一致すれば entries、違えば空（週替わりで忘れる。仕様 s18 §5）。
    public func entriesForCurrentWeek(now: Date, timeZone: TimeZone) -> [JournalEntry] {
        weekKey == Self.weekKey(now: now, timeZone: timeZone) ? entries : []
    }

    /// エントリを追記する。週が替わっていれば過去を空にしてから追記し、`maxEntries` を超えたら古い順に落とす。
    public func appended(_ entry: JournalEntry, now: Date, timeZone: TimeZone) -> StationJournal {
        let currentWeek = Self.weekKey(now: now, timeZone: timeZone)
        var next = (weekKey == currentWeek) ? entries : []   // 週替わりでリセット
        next.append(entry)
        if next.count > Self.maxEntries {
            next.removeFirst(next.count - Self.maxEntries)
        }
        return StationJournal(weekKey: currentWeek, entries: next)
    }
}

/// ジャーナルの永続化（`YamlJournalStore` が準拠。テストで fake 差し替え。仕様 s18 §4）。
public protocol JournalStore: Sendable {
    func load() throws -> StationJournal
    func save(_ journal: StationJournal) throws
}

/// 番組終了時に集める「その回のハイライト」の素材（仕様 s18 §3。確定 A: 日付・ゲスト・特集のみ）。
public struct BroadcastDigest: Sendable, Equatable {
    public var date: String          // "YYYY-MM-DD"
    public var guestName: String?
    public var artistName: String?

    public init(date: String, guestName: String? = nil, artistName: String? = nil) {
        self.date = date
        self.guestName = guestName
        self.artistName = artistName
    }

    /// 振り返る価値のある内容があるか（ゲストも特集も無い回は記録しない）。
    public var hasContent: Bool { guestName != nil || artistName != nil }
}

/// ハイライト要約器（LLM で短い記録文に。失敗時は決定論テンプレ。仕様 s18 §3。fail-tolerant＝throw しない）。
public struct JournalSummarizer: Sendable {
    private let llm: any LLMBackend
    private let temperature: Double

    public init(llm: any LLMBackend, temperature: Double = 0.6) {
        self.llm = llm
        self.temperature = temperature
    }

    /// digest を短い記録文 1 文にする。LLM 失敗・空応答なら決定論フォールバック。
    public func summarize(_ digest: BroadcastDigest) async -> String {
        let request = LLMRequest(
            prompt: """
            次回のラジオ放送の冒頭で「前回はこんな放送でした」と軽く振り返るための、短い記録文を 1 文で書いてください。
            \(Self.facts(digest))
            - 出力は記録文 1 文のみ。日付・「以上」などの定型句や記号装飾は書かない。長くしない。
            """,
            system: "あなたはラジオ番組の記録係です。次回の振り返りに使う短い一文を書きます。",
            temperature: temperature
        )
        if let raw = try? await llm.generate(request) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { return line }
        }
        return Self.fallback(digest)
    }

    static func facts(_ digest: BroadcastDigest) -> String {
        var lines: [String] = []
        if let guest = digest.guestName { lines.append("ゲスト: \(guest)") }
        if let artist = digest.artistName { lines.append("アーティスト特集: \(artist)") }
        return lines.joined(separator: "\n")
    }

    /// 決定論フォールバック（LLM 失敗時。素材が無ければ空文字＝記録しない）。
    static func fallback(_ digest: BroadcastDigest) -> String {
        var parts: [String] = []
        if let guest = digest.guestName { parts.append("ゲストに\(guest)さんを迎え") }
        if let artist = digest.artistName { parts.append("\(artist)さんを特集し") }
        return parts.isEmpty ? "" : parts.joined(separator: "、") + "ました。"
    }
}
