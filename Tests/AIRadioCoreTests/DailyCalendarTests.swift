import Foundation
import Testing
import AIRadioCore

@Suite("DailyCalendar（暦コンテキスト、s17）")
struct DailyCalendarTests {
    private let utc = TimeZone(identifier: "UTC")!
    /// 1970-01-01 00:00 UTC = 木曜日（Calendar weekday 5）。曜日 index の検証に使う固定アンカー。
    private let epoch = Date(timeIntervalSince1970: 0)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test("曜日名は weekdayNames[weekday-1] から引かれる（1970-01-01=木曜=index4）")
    func weekdayLookup() {
        let cal = DailyCalendar(weekdayNames: ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"])
        #expect(cal.context(date: epoch, timeZone: utc).contains("1月1日（THU）"))
    }

    @Test("記念日なし: 日付＋曜日＋季節のみ（記念日文なし）")
    func noAnniversary() {
        let text = DailyCalendar.standard.context(date: date(2026, 6, 14), timeZone: utc)
        #expect(text.contains("6月14日"))
        #expect(text.contains("梅雨の時期です。"))   // SeasonPhrases 6月
        #expect(!text.contains("今日は『"))
    }

    @Test("high（祝日級）: 番組全体に波及させる指示が付く")
    func highAnniversary() {
        let cal = DailyCalendar(anniversaries: [Anniversary(month: 5, day: 5, name: "こどもの日", significance: .high)])
        let text = cal.context(date: date(2026, 5, 5), timeZone: utc)
        #expect(text.contains("今日は『こどもの日』。"))
        #expect(text.contains("番組を通して"))
        #expect(text.contains("こどもの日にちなんだ話題"))
    }

    @Test("low（軽い暦）: 軽く触れる程度の指示が付く")
    func lowAnniversary() {
        let cal = DailyCalendar(anniversaries: [Anniversary(month: 7, day: 7, name: "七夕", significance: .low)])
        let text = cal.context(date: date(2026, 7, 7), timeZone: utc)
        #expect(text.contains("今日は『七夕』。"))
        #expect(text.contains("軽く触れる程度"))
        #expect(!text.contains("番組を通して"))
    }

    @Test("同日に複数の記念日: high を優先して代表1件のみ言及")
    func multiplePrefersHigh() {
        let cal = DailyCalendar(anniversaries: [
            Anniversary(month: 5, day: 5, name: "おまけの日", significance: .low),
            Anniversary(month: 5, day: 5, name: "こどもの日", significance: .high),
        ])
        let text = cal.context(date: date(2026, 5, 5), timeZone: utc)
        #expect(text.contains("こどもの日"))
        #expect(text.contains("番組を通して"))
        #expect(!text.contains("おまけの日"))   // 代表1件のみ
    }
}
