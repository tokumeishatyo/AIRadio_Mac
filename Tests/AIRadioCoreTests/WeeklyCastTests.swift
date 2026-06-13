import Foundation
import Testing
import AIRadioCore

private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

/// 指定の年月日（東京）の Date。
private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = tokyo
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

@Suite("WeeklyCast（曜日替わり編成、s13.5 §2）")
struct WeeklyCastTests {
    @Test("既定表: 全 7 曜日のメイン＋サブ（日曜は 3 人）")
    func standardTableAllDays() {
        let cast = WeeklyCast.standard
        // 2026-06 は 1=月 … 7=日。各曜日の実日付で検証。
        #expect(cast.djIds(for: date(2026, 6, 1), timeZone: tokyo) == ["zundamon", "metan"])        // 月
        #expect(cast.djIds(for: date(2026, 6, 2), timeZone: tokyo) == ["metan", "tsumugi"])          // 火
        #expect(cast.djIds(for: date(2026, 6, 3), timeZone: tokyo) == ["tsumugi", "zundamon"])       // 水
        #expect(cast.djIds(for: date(2026, 6, 4), timeZone: tokyo) == ["zundamon", "metan"])         // 木
        #expect(cast.djIds(for: date(2026, 6, 5), timeZone: tokyo) == ["metan", "tsumugi"])          // 金
        #expect(cast.djIds(for: date(2026, 6, 6), timeZone: tokyo) == ["tsumugi", "zundamon"])       // 土
        #expect(cast.djIds(for: date(2026, 6, 7), timeZone: tokyo) == ["zundamon", "metan", "tsumugi"]) // 日（3 人）
    }

    @Test("メインは編成の先頭")
    func mainIsFirst() {
        let cast = WeeklyCast.standard
        #expect(cast.mainDjId(for: date(2026, 6, 3), timeZone: tokyo) == "tsumugi")  // 水
        #expect(cast.mainDjId(for: date(2026, 6, 7), timeZone: tokyo) == "zundamon") // 日
    }

    @Test("未定義の曜日は空、メインは nil")
    func undefinedDayIsEmpty() {
        let cast = WeeklyCast(casts: [2: ["zundamon"]])  // 月だけ定義
        #expect(cast.djIds(for: date(2026, 6, 2), timeZone: tokyo).isEmpty)  // 火は未定義
        #expect(cast.mainDjId(for: date(2026, 6, 2), timeZone: tokyo) == nil)
    }

    @Test("タイムゾーンを尊重する（UTC 深夜は東京で翌日＝曜日が変わりうる）")
    func respectsTimeZone() {
        // 2026-06-06 23:00 UTC = 東京 6/7 08:00（土 → 日）。
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let moment = utc.date(from: DateComponents(year: 2026, month: 6, day: 6, hour: 23))!
        #expect(WeeklyCast.standard.mainDjId(for: moment, timeZone: tokyo) == "zundamon")  // 東京では日曜
        #expect(WeeklyCast.standard.djIds(for: moment, timeZone: tokyo).count == 3)         // 3 人運営
    }
}
