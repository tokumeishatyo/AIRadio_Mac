import Foundation

/// 記念日の重要度（仕様 s17）。`high` = 祝日級・番組全体に波及／`low` = 軽く触れる程度。
public enum AnniversarySignificance: String, Sendable, Equatable {
    case high
    case low
}

/// 記念日 1 件（`config/calendar.yaml`。仕様 s17）。月日で一致判定する。
public struct Anniversary: Sendable, Equatable {
    public var month: Int
    public var day: Int
    public var name: String
    public var significance: AnniversarySignificance

    public init(month: Int, day: Int, name: String, significance: AnniversarySignificance) {
        self.month = month
        self.day = day
        self.name = name
        self.significance = significance
    }
}

/// 暦コンテキスト（曜日名 + 記念日）。プロンプトに注入する「日付・曜日・季節・記念日」の文を生成する（仕様 s17）。
/// 季節は `SeasonPhrases.phrase(forMonth:)` を流用。`config/calendar.yaml` から読み込む（`DailyCalendarLoader`）。
public struct DailyCalendar: Sendable, Equatable {
    /// 曜日名（index = `Calendar` の weekday - 1。0=日曜 … 6=土曜）。
    public var weekdayNames: [String]
    public var anniversaries: [Anniversary]

    public init(
        weekdayNames: [String] = DailyCalendar.standardWeekdayNames,
        anniversaries: [Anniversary] = []
    ) {
        self.weekdayNames = weekdayNames
        self.anniversaries = anniversaries
    }

    /// 標準の日本語曜日名（`Calendar` の weekday 1=日曜 … 7=土曜の順）。config 省略時のフォールバック。
    public static let standardWeekdayNames = ["日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日"]

    /// config 省略時の既定（標準曜日名・記念日なし）。
    public static let standard = DailyCalendar()

    /// プロンプト注入用の日付コンテキスト。
    /// 例: 「今日は6月14日（土曜日）、梅雨の時期です。」／記念日があれば重要度に応じた一文を付す。
    public func context(date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        let weekdayIndex = (parts.weekday ?? 1) - 1   // Calendar weekday 1..7 → 0..6
        let weekday = weekdayNames.indices.contains(weekdayIndex) ? weekdayNames[weekdayIndex] : ""

        var text = "今日は\(month)月\(day)日"
        if !weekday.isEmpty { text += "（\(weekday)）" }
        text += "、\(SeasonPhrases.phrase(forMonth: month))です。"

        if let anniversary = anniversary(month: month, day: day) {
            switch anniversary.significance {
            case .high:
                text += "今日は『\(anniversary.name)』。番組を通して、\(anniversary.name)にちなんだ話題を意識して織り込んでください。"
            case .low:
                text += "今日は『\(anniversary.name)』。話の流れで軽く触れる程度にとどめてください。"
            }
        }
        return text
    }

    /// その月日の記念日（複数一致なら `high` を優先し、代表 1 件。仕様 s17 §5）。
    private func anniversary(month: Int, day: Int) -> Anniversary? {
        let matches = anniversaries.filter { $0.month == month && $0.day == day }
        return matches.first { $0.significance == .high } ?? matches.first
    }
}
