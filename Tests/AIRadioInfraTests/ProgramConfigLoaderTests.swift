import Foundation
import Testing
import AIRadioCore
@testable import AIRadioInfra

@Suite("ProgramConfigLoader")
struct ProgramConfigLoaderTests {
    @Test("番組フォーマットを読み込む")
    func loadsProgram() throws {
        let yaml = """
        program:
          title: "ケイラボAIラジオ"
          anchor_dj_id: zundamon
          segments:
            - type: opening
            - type: talk
              corner_id: free_talk
            - type: news
            - type: ending
        """
        let program = try ProgramConfigLoader.load(yaml: yaml)
        #expect(program == Program(
            title: "ケイラボAIラジオ",
            anchorDjId: "zundamon",
            segments: [
                ProgramSegment(kind: .opening),
                ProgramSegment(kind: .talk, cornerId: "free_talk"),
                ProgramSegment(kind: .news),
                ProgramSegment(kind: .ending),
            ]
        ))
    }

    @Test("critical を読み込む（省略時 false）")
    func loadsCritical() throws {
        let yaml = """
        program:
          anchor_dj_id: zundamon
          segments:
            - type: opening
              critical: true
            - type: news
        """
        let program = try ProgramConfigLoader.load(yaml: yaml)
        #expect(program.segments[0].critical == true)
        #expect(program.segments[1].critical == false)
    }

    @Test("title は省略時に既定値")
    func defaultsTitle() throws {
        let yaml = """
        program:
          anchor_dj_id: zundamon
          segments:
            - type: opening
        """
        #expect(try ProgramConfigLoader.load(yaml: yaml).title == "ケイラボAIラジオ")
    }

    @Test("anchor_dj_id / segments / talk の corner_id / 不正 type は設定エラー")
    func invalidConfigsThrow() {
        #expect(throws: ConfigError.self) {
            _ = try ProgramConfigLoader.load(yaml: "program:\n  segments:\n    - type: opening\n")
        }
        #expect(throws: ConfigError.self) {
            _ = try ProgramConfigLoader.load(yaml: "program:\n  anchor_dj_id: z\n  segments: []\n")
        }
        #expect(throws: ConfigError.self) {
            _ = try ProgramConfigLoader.load(yaml: """
            program:
              anchor_dj_id: z
              segments:
                - type: talk
            """)
        }
        #expect(throws: ConfigError.self) {
            _ = try ProgramConfigLoader.load(yaml: """
            program:
              anchor_dj_id: z
              segments:
                - type: weather_dance
            """)
        }
    }
}
