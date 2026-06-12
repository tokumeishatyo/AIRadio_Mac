import Foundation
import Testing
import AIRadioCore

private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

private func date(month: Int, day: Int) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = month
    components.day = day
    components.hour = 12
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = tokyo
    return calendar.date(from: components)!
}

@Suite("SeasonPhrases")
struct SeasonPhrasesTests {
    @Test("全 12 か月の季節の言い回し（仕様 s12 §4）")
    func allMonths() {
        let expected: [Int: String] = [
            1: "冬、正月明け", 2: "冬の終わり", 3: "春の始まり", 4: "春",
            5: "初夏、新緑の季節", 6: "梅雨の時期", 7: "盛夏", 8: "真夏、残暑",
            9: "初秋", 10: "秋", 11: "晩秋", 12: "冬、年の瀬",
        ]
        for (month, phrase) in expected {
            #expect(SeasonPhrases.phrase(forMonth: month) == phrase, "\(month) 月")
        }
    }

    @Test("dateContext は日付 + 季節の言い回しを組み立てる")
    func dateContextFormatsDateAndSeason() {
        #expect(SeasonPhrases.dateContext(date: date(month: 6, day: 12), timeZone: tokyo)
            == "今日は6月12日、梅雨の時期です。")
        #expect(SeasonPhrases.dateContext(date: date(month: 12, day: 31), timeZone: tokyo)
            == "今日は12月31日、冬、年の瀬です。")
    }

    @Test("タイムゾーンを尊重する（UTC 末日 → 東京では翌月）")
    func respectsTimeZone() {
        // 2026-05-31 23:00 UTC = 東京 6/1 08:00
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 31
        components.hour = 23
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let moment = utc.date(from: components)!
        #expect(SeasonPhrases.dateContext(date: moment, timeZone: tokyo) == "今日は6月1日、梅雨の時期です。")
    }
}
