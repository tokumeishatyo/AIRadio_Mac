import Foundation
import Testing
import AIRadioCore
@testable import AIRadioInfra

@Suite("DjsConfigLoader")
struct DjsConfigLoaderTests {
    @Test("DJ 一覧を読み込む")
    func loadsDjs() throws {
        let yaml = """
        djs:
          - id: zundamon
            name: "ずんだもん"
            speaker_id: 3
            persona: "なのだ口調"
          - id: metan
            name: "四国めたん"
            speaker_id: 2
        """
        let djs = try DjsConfigLoader.load(yaml: yaml)
        #expect(djs == [
            DjProfile(id: "zundamon", name: "ずんだもん", speakerId: 3, persona: "なのだ口調"),
            DjProfile(id: "metan", name: "四国めたん", speakerId: 2, persona: ""),
        ])
    }

    @Test("空・必須フィールド欠落は設定エラー")
    func missingFieldsThrow() {
        #expect(throws: ConfigError.self) { _ = try DjsConfigLoader.load(yaml: "djs: []") }
        #expect(throws: ConfigError.self) {
            _ = try DjsConfigLoader.load(yaml: "djs:\n  - id: x\n    name: \"X\"\n")  // speaker_id なし
        }
    }
}
