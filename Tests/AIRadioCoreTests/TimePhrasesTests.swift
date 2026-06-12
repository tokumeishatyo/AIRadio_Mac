import Foundation
import Testing
import AIRadioCore

private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = tokyo
    return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

@Suite("TimeOfDay: 時間帯境界（Windows 版踏襲）")
struct TimeOfDayTests {
    @Test("朝 5-11 / 昼 12-16 / 夜 17-4（深夜またぎ）")
    func boundaries() {
        #expect(TimeOfDay.of(hour: 4) == .evening)
        #expect(TimeOfDay.of(hour: 5) == .morning)
        #expect(TimeOfDay.of(hour: 11) == .morning)
        #expect(TimeOfDay.of(hour: 12) == .afternoon)
        #expect(TimeOfDay.of(hour: 16) == .afternoon)
        #expect(TimeOfDay.of(hour: 17) == .evening)
        #expect(TimeOfDay.of(hour: 0) == .evening)
        #expect(TimeOfDay.of(hour: 23) == .evening)
    }
}

@Suite("TimePhrases")
struct TimePhrasesTests {
    @Test("午後の例（6/12 15:07）: 挨拶・日付・NHK 式・12 時間表記")
    func afternoonValues() {
        let values = TimePhrases.values(date: date(6, 12, 15, 7), timeZone: tokyo)
        #expect(values["greeting"] == "こんにちは")
        #expect(values["month"] == "6")
        #expect(values["day"] == "12")
        #expect(values["ampm"] == "午後")
        #expect(values["hour"] == "3")     // 午後3時
        #expect(values["hour12"] == "3")   // 3時7分
        #expect(values["minute"] == "7")
    }

    @Test("朝の例（1/5 9:00）")
    func morningValues() {
        let values = TimePhrases.values(date: date(1, 5, 9, 0), timeZone: tokyo)
        #expect(values["greeting"] == "おはようございます")
        #expect(values["ampm"] == "午前")
        #expect(values["hour"] == "9")
        #expect(values["hour12"] == "9")
        #expect(values["minute"] == "0")
    }

    @Test("正午 12:05 は NHK 式「午後0時」/ 午前午後なしは「12時」")
    func noonValues() {
        let values = TimePhrases.values(date: date(6, 12, 12, 5), timeZone: tokyo)
        #expect(values["greeting"] == "こんにちは")
        #expect(values["ampm"] == "午後")
        #expect(values["hour"] == "0")     // 午後0時（NHK 式）
        #expect(values["hour12"] == "12")  // 12時5分
    }

    @Test("深夜 0:30 は「午前0時」/「0時30分」、挨拶はこんばんは")
    func midnightValues() {
        let values = TimePhrases.values(date: date(6, 12, 0, 30), timeZone: tokyo)
        #expect(values["greeting"] == "こんばんは")
        #expect(values["ampm"] == "午前")
        #expect(values["hour"] == "0")
        #expect(values["hour12"] == "0")
    }

    @Test("挨拶文字列は設定（greetings）から差し替えられる")
    func customGreetings() {
        let greetings = Greetings(morning: "おっはよ〜", afternoon: "ちわ", evening: "ばんは")
        let values = TimePhrases.values(date: date(6, 12, 6, 0), greetings: greetings, timeZone: tokyo)
        #expect(values["greeting"] == "おっはよ〜")
    }

    @Test("TemplateExpander との結合: OP・ニュースの文言が仕様どおり展開される")
    func expandsTemplates() {
        let values = TimePhrases.values(date: date(6, 12, 15, 7), timeZone: tokyo)
        let op = TemplateExpander.expand(
            "{greeting}。{month}月{day}日、{ampm}{hour}時になりました。", values: values)
        #expect(op == "こんにちは。6月12日、午後3時になりました。")
        let news = TemplateExpander.expand(
            "時刻は{hour12}時{minute}分になりました。ニュースの時間です。", values: values)
        #expect(news == "時刻は3時7分になりました。ニュースの時間です。")
    }
}
