import Foundation

/// 月 → 季節の言い回し（仕様 s12 §4、境界はハードコード）。
/// 台本生成プロンプトに日付・季節を注入し、「6 月に春めいて三寒四温」のような季節ズレを防ぐ。
public enum SeasonPhrases {
    /// 月（1〜12）に対応する季節の言い回し。
    public static func phrase(forMonth month: Int) -> String {
        switch month {
        case 1: return "冬、正月明け"
        case 2: return "冬の終わり"
        case 3: return "春の始まり"
        case 4: return "春"
        case 5: return "初夏、新緑の季節"
        case 6: return "梅雨の時期"
        case 7: return "盛夏"
        case 8: return "真夏、残暑"
        case 9: return "初秋"
        case 10: return "秋"
        case 11: return "晩秋"
        default: return "冬、年の瀬"
        }
    }

    /// プロンプト注入用の日付コンテキスト（例: 「今日は6月12日、梅雨の時期です。」）。
    public static func dateContext(date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day], from: date)
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        return "今日は\(month)月\(day)日、\(phrase(forMonth: month))です。"
    }
}
