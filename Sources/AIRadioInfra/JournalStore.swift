import Foundation
import Yams
import AIRadioCore

/// `config/journal.local.yaml` への `StationJournal` 永続化（長期記憶。仕様 s18 §4）。
/// ファイル無し＝空ジャーナル。壊れていたら decode で throw するが、呼び出し側（`BroadcastEngine`）が
/// `try?` で握り潰して空にする（長期記憶は事故ゼロ系＝壊れても放送を止めない）。人為削除で即クリア。
public struct YamlJournalStore: JournalStore {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    private struct File: Codable {
        struct Entry: Codable {
            let date: String
            let highlight: String
        }
        let week_key: String
        let entries: [Entry]
    }

    public func load() throws -> StationJournal {
        guard FileManager.default.fileExists(atPath: path) else { return .empty }
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        return StationJournal(
            weekKey: file.week_key,
            entries: file.entries.map { JournalEntry(date: $0.date, highlight: $0.highlight) }
        )
    }

    public func save(_ journal: StationJournal) throws {
        let file = File(
            week_key: journal.weekKey,
            entries: journal.entries.map { File.Entry(date: $0.date, highlight: $0.highlight) }
        )
        let yaml = try YAMLEncoder().encode(file)
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
