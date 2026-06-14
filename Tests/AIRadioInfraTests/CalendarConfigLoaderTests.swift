import Foundation
import Testing
import AIRadioCore
@testable import AIRadioInfra

@Suite("DailyCalendarLoader（calendar.yaml、s17）")
struct CalendarConfigLoaderTests {
    @Test("正常: weekday_names と anniversaries（high/low）を読む")
    func loadsValid() throws {
        let yaml = """
        weekday_names: ["日", "月", "火", "水", "木", "金", "土"]
        anniversaries:
          - { date: "05-05", name: "こどもの日", significance: high }
          - { date: "07-07", name: "七夕", significance: low }
        """
        let cal = try DailyCalendarLoader.load(yaml: yaml)
        #expect(cal.weekdayNames == ["日", "月", "火", "水", "木", "金", "土"])
        #expect(cal.anniversaries.count == 2)
        #expect(cal.anniversaries[0] == Anniversary(month: 5, day: 5, name: "こどもの日", significance: .high))
        #expect(cal.anniversaries[1].significance == .low)
    }

    @Test("weekday_names 省略は標準曜日名")
    func defaultWeekdayNames() throws {
        let cal = try DailyCalendarLoader.load(yaml: "anniversaries: []")
        #expect(cal.weekdayNames == DailyCalendar.standardWeekdayNames)
        #expect(cal.anniversaries.isEmpty)
    }

    @Test("significance 省略は low 扱い")
    func significanceDefaultsToLow() throws {
        let cal = try DailyCalendarLoader.load(yaml: """
        anniversaries:
          - { date: "11-22", name: "いい夫婦の日" }
        """)
        #expect(cal.anniversaries[0].significance == .low)
    }

    @Test("significance 不正値は throw")
    func invalidSignificanceThrows() {
        #expect(throws: ConfigError.self) {
            try DailyCalendarLoader.load(yaml: """
            anniversaries:
              - { date: "01-01", name: "元日", significance: medium }
            """)
        }
    }

    @Test("date が MM-DD でないと throw")
    func invalidDateThrows() {
        #expect(throws: ConfigError.self) {
            try DailyCalendarLoader.load(yaml: """
            anniversaries:
              - { date: "0101", name: "元日", significance: high }
            """)
        }
    }

    @Test("weekday_names が7要素でないと throw")
    func wrongWeekdayCountThrows() {
        #expect(throws: ConfigError.self) {
            try DailyCalendarLoader.load(yaml: """
            weekday_names: ["日", "月"]
            """)
        }
    }
}
