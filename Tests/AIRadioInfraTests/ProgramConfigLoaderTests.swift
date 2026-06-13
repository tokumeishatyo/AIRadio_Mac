import Foundation
import Testing
import AIRadioCore
@testable import AIRadioInfra

private let fullYaml = """
program:
  title: "ケイラボAIラジオ"
  anchor_dj_id: zundamon
  default_length: 10
  opening:
    critical: true
  song:
    song_prompt_hint: "幕開けの曲"
    fallback_track_uri: "https://open.spotify.com/track/5jsqaNOAbeBG5QYL7JpySJ?si=x"
    volume: 100
    play_seconds: 0
  talk:
    corner_id: free_talk
  letter:
    corner_id: letter
  news:
    dj_id: ryusei
"""

@Suite("ProgramConfigLoader（v2 部品宣言、s13 §6）")
struct ProgramConfigLoaderTests {
    @Test("部品宣言を読み込む（URI 正規化込み）")
    func loadsBlueprint() throws {
        let blueprint = try ProgramConfigLoader.load(yaml: fullYaml)
        #expect(blueprint == ProgramBlueprint(
            title: "ケイラボAIラジオ",
            anchorDjId: "zundamon",
            defaultLength: .corners(10),
            openingCritical: true,
            song: SongSegmentSpec(
                promptHint: "幕開けの曲",
                fallbackTrackUri: "spotify:track:5jsqaNOAbeBG5QYL7JpySJ",
                volume: 100,
                playSeconds: 0
            ),
            talkCornerId: "free_talk",
            letterCornerId: "letter",
            newsDjId: "ryusei"
        ))
    }

    @Test("default_length: endless / 文字列の数値 / 省略時 10")
    func parsesDefaultLength() throws {
        let endless = fullYaml.replacingOccurrences(of: "default_length: 10", with: "default_length: endless")
        #expect(try ProgramConfigLoader.load(yaml: endless).defaultLength == .endless)

        let quoted = fullYaml.replacingOccurrences(of: "default_length: 10", with: "default_length: \"20\"")
        #expect(try ProgramConfigLoader.load(yaml: quoted).defaultLength == .corners(20))

        let omitted = fullYaml.replacingOccurrences(of: "  default_length: 10\n", with: "")
        #expect(try ProgramConfigLoader.load(yaml: omitted).defaultLength == .corners(10))
    }

    @Test("default_length の不正値（0 / 負 / 文字列）は fail-fast")
    func invalidDefaultLengthThrows() {
        for bad in ["default_length: 0", "default_length: -5", "default_length: short"] {
            let yaml = fullYaml.replacingOccurrences(of: "default_length: 10", with: bad)
            #expect(throws: ConfigError.self, "\(bad)") {
                _ = try ProgramConfigLoader.load(yaml: yaml)
            }
        }
    }

    @Test("省略可能な項目の既定値（title / opening.critical / news / song の volume 等）")
    func defaults() throws {
        let minimal = """
        program:
          anchor_dj_id: zundamon
          song:
            fallback_track_uri: "spotify:track:X"
          talk:
            corner_id: free_talk
          letter:
            corner_id: letter
        """
        let blueprint = try ProgramConfigLoader.load(yaml: minimal)
        #expect(blueprint.title == "ケイラボAIラジオ")
        #expect(blueprint.openingCritical == true)
        #expect(blueprint.newsDjId == nil)
        #expect(blueprint.song.volume == 100)
        #expect(blueprint.song.playSeconds == 0)
        #expect(blueprint.defaultLength == .corners(10))
    }

    @Test("必須欠落（anchor / song / fallback_track_uri / talk / letter）は設定エラー")
    func missingRequiredFieldsThrow() {
        let requiredRemovals = [
            ("  anchor_dj_id: zundamon\n", ""),
            ("  song:\n    song_prompt_hint: \"幕開けの曲\"\n    fallback_track_uri: \"https://open.spotify.com/track/5jsqaNOAbeBG5QYL7JpySJ?si=x\"\n    volume: 100\n    play_seconds: 0\n", ""),
            ("    fallback_track_uri: \"https://open.spotify.com/track/5jsqaNOAbeBG5QYL7JpySJ?si=x\"\n", ""),
            ("  talk:\n    corner_id: free_talk\n", ""),
            ("  letter:\n    corner_id: letter\n", ""),
        ]
        for (target, replacement) in requiredRemovals {
            let yaml = fullYaml.replacingOccurrences(of: target, with: replacement)
            #expect(yaml != fullYaml, "置換対象が見つからない: \(target)")
            #expect(throws: ConfigError.self) {
                _ = try ProgramConfigLoader.load(yaml: yaml)
            }
        }
    }

    // MARK: - weekly_cast（s13.5）

    @Test("weekly_cast 省略時は既定表（WeeklyCast.standard）")
    func weeklyCastDefaultsToStandard() throws {
        #expect(try ProgramConfigLoader.load(yaml: fullYaml).weeklyCast == .standard)
    }

    @Test("weekly_cast を曜日名→Calendar weekday で読み込む")
    func loadsWeeklyCast() throws {
        let yaml = fullYaml + """

          weekly_cast:
            monday: [zundamon, metan]
            sunday: [zundamon, metan, tsumugi]
        """
        let cast = try ProgramConfigLoader.load(yaml: yaml).weeklyCast
        #expect(cast.casts[2] == ["zundamon", "metan"])             // 月=2
        #expect(cast.casts[1] == ["zundamon", "metan", "tsumugi"])  // 日=1
    }

    @Test("不正な曜日名 / 空の編成は設定エラー")
    func invalidWeeklyCastThrows() {
        let badDay = fullYaml + "\n  weekly_cast:\n    someday: [zundamon]\n"
        #expect(throws: ConfigError.self) { _ = try ProgramConfigLoader.load(yaml: badDay) }
        let emptyDay = fullYaml + "\n  weekly_cast:\n    monday: []\n"
        #expect(throws: ConfigError.self) { _ = try ProgramConfigLoader.load(yaml: emptyDay) }
    }
}
