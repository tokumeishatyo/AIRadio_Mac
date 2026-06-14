import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

struct PronunciationsConfigLoaderTests {
    @Test("空文字・pronunciations 空・コメントのみは正常＝空辞書")
    func emptyIsValid() throws {
        #expect(try PronunciationsConfigLoader.load(yaml: "") == [])
        #expect(try PronunciationsConfigLoader.load(yaml: "pronunciations: []") == [])
        #expect(try PronunciationsConfigLoader.load(yaml: "# comment only\n") == [])
    }

    @Test("正常: surface / pronunciation / accent_type / word_type / priority を読む")
    func valid() throws {
        let yaml = """
        pronunciations:
          - surface: "栄光の架橋"
            pronunciation: "エイコウノカケハシ"
          - surface: "Mr.Children"
            pronunciation: "ミスターチルドレン"
            accent_type: 1
            word_type: PROPER_NOUN
            priority: 8
        """
        let entries = try PronunciationsConfigLoader.load(yaml: yaml)
        #expect(entries == [
            PronunciationEntry(surface: "栄光の架橋", pronunciation: "エイコウノカケハシ"),
            PronunciationEntry(
                surface: "Mr.Children", pronunciation: "ミスターチルドレン",
                accentType: 1, wordType: "PROPER_NOUN", priority: 8),
        ])
    }

    @Test("accent_type 省略で既定 0")
    func accentTypeDefaultsToZero() throws {
        let entries = try PronunciationsConfigLoader.load(yaml: """
        pronunciations:
          - surface: "お家"
            pronunciation: "オウチ"
        """)
        #expect(entries.first?.accentType == 0)
        #expect(entries.first?.wordType == nil)
        #expect(entries.first?.priority == nil)
    }

    @Test("壊れている: surface / pronunciation 欠落は throw")
    func malformedThrows() {
        #expect(throws: ConfigError.self) {
            try PronunciationsConfigLoader.load(yaml: "pronunciations:\n  - surface: \"X\"\n")  // pronunciation なし
        }
        #expect(throws: ConfigError.self) {
            try PronunciationsConfigLoader.load(yaml: "pronunciations:\n  - pronunciation: \"エックス\"\n")  // surface なし
        }
    }

    @Test("ファイルが無いのは正常（空辞書）")
    func missingFileIsEmpty() throws {
        #expect(try PronunciationsConfigLoader.load(path: "/no/such/pronunciations.yaml") == [])
    }
}
