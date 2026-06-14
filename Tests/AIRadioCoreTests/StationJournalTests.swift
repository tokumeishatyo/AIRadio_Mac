import Foundation
import Testing
import AIRadioCore
import AIRadioTestSupport

private struct FailingLLM: LLMBackend {
    struct Failure: Error {}
    func generate(_ request: LLMRequest) async throws -> String { throw Failure() }
}

@Suite("StationJournal（長期記憶、s18）")
struct StationJournalTests {
    private let tz = TimeZone(identifier: "Asia/Tokyo")!
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @Test("週キーは ISO 週（月曜始まり）: 月〜日が同週、翌月曜で替わる")
    func weekKeyMondayStart() {
        let sat = StationJournal.weekKey(now: date(2026, 6, 13), timeZone: tz)  // 土
        let sun = StationJournal.weekKey(now: date(2026, 6, 14), timeZone: tz)  // 日
        let mon = StationJournal.weekKey(now: date(2026, 6, 15), timeZone: tz)  // 月（翌週）
        #expect(sat == sun)    // 同じ ISO 週
        #expect(sun != mon)    // 月曜で週替わり
    }

    @Test("当週一致で entries、週違いで空")
    func entriesForCurrentWeek() {
        let key = StationJournal.weekKey(now: date(2026, 6, 14), timeZone: tz)
        let journal = StationJournal(weekKey: key, entries: [JournalEntry(date: "2026-06-14", highlight: "h")])
        #expect(journal.entriesForCurrentWeek(now: date(2026, 6, 14), timeZone: tz).count == 1)
        #expect(journal.entriesForCurrentWeek(now: date(2026, 6, 15), timeZone: tz).isEmpty)  // 翌週は空
    }

    @Test("appended: 週替わりで過去を捨ててから追記（月曜クリア）")
    func appendedResetsOnNewWeek() {
        let oldKey = StationJournal.weekKey(now: date(2026, 6, 14), timeZone: tz)  // 先週（日）
        let journal = StationJournal(weekKey: oldKey, entries: [JournalEntry(date: "2026-06-14", highlight: "先週")])
        let updated = journal.appended(JournalEntry(date: "2026-06-15", highlight: "今週"), now: date(2026, 6, 15), timeZone: tz)
        #expect(updated.entries.map(\.highlight) == ["今週"])   // 先週分は消える
        #expect(updated.weekKey == StationJournal.weekKey(now: date(2026, 6, 15), timeZone: tz))
    }

    @Test("appended: 同週は追記、maxEntries 超で古い順に落とす（リングバッファ）")
    func appendedRingBuffer() {
        let key = StationJournal.weekKey(now: date(2026, 6, 15), timeZone: tz)
        var journal = StationJournal(weekKey: key, entries: (1...7).map { JournalEntry(date: "d\($0)", highlight: "h\($0)") })
        journal = journal.appended(JournalEntry(date: "d8", highlight: "h8"), now: date(2026, 6, 15), timeZone: tz)
        #expect(journal.entries.count == StationJournal.maxEntries)  // 7
        #expect(journal.entries.first?.highlight == "h2")   // h1 が落ちる
        #expect(journal.entries.last?.highlight == "h8")
    }
}

@Suite("JournalSummarizer（s18）")
struct JournalSummarizerTests {
    @Test("LLM 応答を記録文にする（前後空白は除去）")
    func usesLlm() async {
        let summarizer = JournalSummarizer(llm: ScriptedLLM(responses: ["  ゲストに九州そらさんを迎えました。 "]))
        let text = await summarizer.summarize(BroadcastDigest(date: "2026-06-14", guestName: "九州そら"))
        #expect(text == "ゲストに九州そらさんを迎えました。")
    }

    @Test("LLM 失敗時は決定論フォールバック（ゲスト・特集を文に）")
    func fallbackOnFailure() async {
        let summarizer = JournalSummarizer(llm: FailingLLM())
        let text = await summarizer.summarize(BroadcastDigest(date: "2026-06-14", guestName: "あんこもん", artistName: "米津玄師"))
        #expect(text.contains("あんこもん"))
        #expect(text.contains("米津玄師"))
    }

    @Test("素材が無ければフォールバックは空（記録しない）")
    func emptyWhenNoContent() async {
        // LLM 失敗時に素材も無ければ空文字（呼び出し側は空なら記録しない）。
        let text = await JournalSummarizer(llm: FailingLLM()).summarize(BroadcastDigest(date: "x"))
        #expect(text == "")
        #expect(BroadcastDigest(date: "x").hasContent == false)
        #expect(BroadcastDigest(date: "x", guestName: "g").hasContent == true)
    }
}
