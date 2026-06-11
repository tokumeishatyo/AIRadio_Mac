import Foundation
import Testing
import AIRadioCore
@testable import AIRadioInfra

@Suite("CornersConfigLoader")
struct CornersConfigLoaderTests {
    @Test("コーナーを読み込み、fallback URI を正規化し、省略値を補う")
    func loadsCorner() throws {
        let yaml = """
        corners:
          - id: free_talk
            title: "フリートーク"
            theme: "最近気になっていること"
            dj_ids: [zundamon, metan]
            fallback_track_uri: "https://open.spotify.com/track/5jsqaNOAbeBG5QYL7JpySJ?si=x"
        """
        let corners = try CornersConfigLoader.load(yaml: yaml)
        #expect(corners.count == 1)
        let corner = corners[0]
        #expect(corner.id == "free_talk")
        #expect(corner.djIds == ["zundamon", "metan"])
        #expect(corner.fallbackTrackUri == "spotify:track:5jsqaNOAbeBG5QYL7JpySJ")
        #expect(corner.targetMinutes == 5)
        #expect(corner.charsPerMinute == 320)
        #expect(corner.targetCharacters == 1600)
        #expect(corner.volume == 85)
        #expect(corner.playSeconds == 0)
    }

    @Test("明示した値が省略値より優先される")
    func explicitValuesWin() throws {
        let yaml = """
        corners:
          - id: c
            title: "T"
            theme: "TH"
            dj_ids: [a]
            target_minutes: 3
            chars_per_minute: 300
            song_prompt_hint: "ヒント"
            fallback_track_uri: "spotify:track:X"
            volume: 70
            play_seconds: 45
        """
        let corner = try CornersConfigLoader.load(yaml: yaml)[0]
        #expect(corner.targetMinutes == 3)
        #expect(corner.charsPerMinute == 300)
        #expect(corner.songPromptHint == "ヒント")
        #expect(corner.volume == 70)
        #expect(corner.playSeconds == 45)
    }

    @Test("theme / dj_ids / fallback_track_uri の欠落は設定エラー")
    func missingFieldsThrow() {
        #expect(throws: ConfigError.self) { _ = try CornersConfigLoader.load(yaml: "corners: []") }
        #expect(throws: ConfigError.self) {
            _ = try CornersConfigLoader.load(yaml: """
            corners:
              - id: c
                title: "T"
                dj_ids: [a]
                fallback_track_uri: "spotify:track:X"
            """)
        }
        #expect(throws: ConfigError.self) {
            _ = try CornersConfigLoader.load(yaml: """
            corners:
              - id: c
                title: "T"
                theme: "TH"
                dj_ids: [a]
            """)
        }
    }
}
