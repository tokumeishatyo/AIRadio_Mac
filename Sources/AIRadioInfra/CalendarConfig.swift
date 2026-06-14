import Foundation
import Yams
import AIRadioCore

/// `config/calendar.yaml` のローダ（曜日名 + 記念日。仕様 s17）。
/// `weekday_names` 省略時は標準曜日名、`anniversaries` 省略時は空。壊れ・不正値は throw（CFG, fail-fast）。
public enum DailyCalendarLoader {
    private struct File: Decodable {
        struct Entry: Decodable {
            let date: String?
            let name: String?
            let significance: String?
        }
        let weekday_names: [String]?
        let anniversaries: [Entry]?
    }

    public static func load(yaml: String) throws -> DailyCalendar {
        let file = try YAMLDecoder().decode(File.self, from: yaml)

        let weekdayNames: [String]
        if let names = file.weekday_names {
            guard names.count == 7 else {
                throw ConfigError.missingField("calendar.weekday_names は7要素にしてください（現在 \(names.count)）")
            }
            weekdayNames = names
        } else {
            weekdayNames = DailyCalendar.standardWeekdayNames
        }

        let anniversaries = try (file.anniversaries ?? []).map { entry -> Anniversary in
            guard let date = entry.date, let name = entry.name, !name.isEmpty else {
                throw ConfigError.missingField("calendar.anniversaries[].date / name は必須です")
            }
            let parts = date.split(separator: "-")
            guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
                  (1...12).contains(month), (1...31).contains(day) else {
                throw ConfigError.missingField("calendar.anniversaries[].date は MM-DD 形式: \(date)")
            }
            let significance: AnniversarySignificance
            switch entry.significance {
            case "high": significance = .high
            case "low", .none: significance = .low   // 省略時は軽い暦扱い
            default:
                throw ConfigError.missingField("calendar.anniversaries[].significance は high / low: \(entry.significance ?? "")")
            }
            return Anniversary(month: month, day: day, name: name, significance: significance)
        }

        return DailyCalendar(weekdayNames: weekdayNames, anniversaries: anniversaries)
    }

    public static func load(path: String) throws -> DailyCalendar {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }
}
