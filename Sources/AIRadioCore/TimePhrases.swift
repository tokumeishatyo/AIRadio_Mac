import Foundation

/// 時間帯の区分（Windows 版 docs/specs/daily-context.md §6-4 を踏襲、境界はハードコード）。
public enum TimeOfDay: Sendable, Equatable {
    /// 朝（05:00–11:59）。「おはようございます」。
    case morning
    /// 昼（12:00–16:59）。「こんにちは」。
    case afternoon
    /// 夜（17:00–04:59、深夜またぎ）。「こんばんは」。
    case evening

    public static func of(hour: Int) -> TimeOfDay {
        switch hour {
        case 5...11: return .morning
        case 12...16: return .afternoon
        default: return .evening
        }
    }
}

/// 時間帯ごとの挨拶文字列（`config/themes.yaml` の `greetings:` から。Windows 版 greetings.yaml と同形）。
public struct Greetings: Sendable, Equatable {
    public var morning: String
    public var afternoon: String
    public var evening: String

    public init(
        morning: String = "おはようございます",
        afternoon: String = "こんにちは",
        evening: String = "こんばんは"
    ) {
        self.morning = morning
        self.afternoon = afternoon
        self.evening = evening
    }

    public func text(for timeOfDay: TimeOfDay) -> String {
        switch timeOfDay {
        case .morning: return morning
        case .afternoon: return afternoon
        case .evening: return evening
        }
    }
}

/// 現在時刻からアナウンス用プレースホルダ値を生成する純粋ロジック（仕様 s8 §3）。
/// `TemplateExpander` と組で使う。発話直前に展開することで時報として正確になる。
public enum TimePhrases {
    /// - `{greeting}`: 時間帯挨拶
    /// - `{month}` / `{day}` / `{minute}`: 数値（ゼロ埋めなし）
    /// - `{ampm}` + `{hour}`: NHK 式 12 時間表記（午前0–11時 / 午後0–11時。12:xx は「午後0時」）
    /// - `{hour12}`: 午前/午後なしの 12 時間表記（0:xx→0、12:xx→12、それ以外 1–11）
    public static func values(
        date: Date,
        greetings: Greetings = Greetings(),
        timeZone: TimeZone = .current
    ) -> [String: String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let hour24 = parts.hour ?? 0
        let hour12NoAmpm: Int
        if hour24 == 0 {
            hour12NoAmpm = 0
        } else if hour24 % 12 == 0 {
            hour12NoAmpm = 12
        } else {
            hour12NoAmpm = hour24 % 12
        }
        return [
            "greeting": greetings.text(for: TimeOfDay.of(hour: hour24)),
            "month": String(parts.month ?? 0),
            "day": String(parts.day ?? 0),
            "ampm": hour24 < 12 ? "午前" : "午後",
            "hour": String(hour24 % 12),
            "hour12": String(hour12NoAmpm),
            "minute": String(parts.minute ?? 0),
        ]
    }
}
