import Foundation
import Testing
import AIRadioCore
@testable import AIRadioInfra

@Suite("YamlJournalStore（journal.local.yaml、s18）")
struct JournalStoreTests {
    private func tmp() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("airadio-journal-\(UUID().uuidString).yaml").path
    }

    @Test("save → load の往復")
    func roundtrip() throws {
        let path = tmp()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = YamlJournalStore(path: path)
        let journal = StationJournal(weekKey: "2026-W24", entries: [
            JournalEntry(date: "2026-06-14", highlight: "ゲストに九州そらさんを迎えました。"),
            JournalEntry(date: "2026-06-15", highlight: "米津玄師さんを特集しました。"),
        ])
        try store.save(journal)
        #expect(try store.load() == journal)
    }

    @Test("ファイル無し＝空ジャーナル")
    func missingFileIsEmpty() throws {
        #expect(try YamlJournalStore(path: tmp()).load() == StationJournal.empty)
    }

    @Test("壊れた yaml は throw（呼び出し側が try? で空に倒す）")
    func corruptThrows() throws {
        let path = tmp()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "this is not the journal schema".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try YamlJournalStore(path: path).load() }
    }
}
