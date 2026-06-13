import Foundation
import Testing
import AIRadioCore
@testable import AIRadioInfra

@Suite("GuestsConfigLoader（s14）")
struct GuestsConfigLoaderTests {
    @Test("ゲストプールを読み込む（id / name / speaker_id / persona）")
    func loadsGuests() throws {
        let yaml = """
        guests:
          - id: sora
            name: "九州そら"
            speaker_id: 16
            persona: "おっとり穏やか"
          - id: ankomon
            name: "あんこもん"
            speaker_id: 113
            persona: "語尾に「もん」"
        """
        let guests = try GuestsConfigLoader.load(yaml: yaml)
        #expect(guests.count == 2)
        #expect(guests[0] == DjProfile(id: "sora", name: "九州そら", speakerId: 16, persona: "おっとり穏やか"))
        #expect(guests[1].id == "ankomon")
        #expect(guests[1].speakerId == 113)
    }

    @Test("persona 省略時は空文字")
    func personaDefaultsEmpty() throws {
        let guest = try GuestsConfigLoader.load(yaml: """
        guests:
          - id: g
            name: "ゲスト"
            speaker_id: 10
        """)[0]
        #expect(guest.persona == "")
    }

    @Test("空 / 必須欠落は設定エラー")
    func missingFieldsThrow() {
        #expect(throws: ConfigError.self) { _ = try GuestsConfigLoader.load(yaml: "guests: []") }
        #expect(throws: ConfigError.self) {
            _ = try GuestsConfigLoader.load(yaml: """
            guests:
              - id: g
                name: "ゲスト"
            """)  // speaker_id 欠落
        }
        #expect(throws: ConfigError.self) {
            _ = try GuestsConfigLoader.load(yaml: """
            guests:
              - name: "名前のみ"
                speaker_id: 1
            """)  // id 欠落
        }
    }
}
