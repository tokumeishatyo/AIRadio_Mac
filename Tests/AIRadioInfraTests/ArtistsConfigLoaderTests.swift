import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

struct ArtistsConfigLoaderTests {
    @Test("空文字・artists 空・null は正常＝空プール（出荷時の空ファイル）")
    func emptyIsValid() throws {
        #expect(try ArtistsConfigLoader.load(yaml: "") == [])
        #expect(try ArtistsConfigLoader.load(yaml: "artists: []") == [])
        #expect(try ArtistsConfigLoader.load(yaml: "# comment only\n") == [])
    }

    @Test("正常: id / name を読む")
    func valid() throws {
        let yaml = """
        artists:
          - id: artist_001
            name: "米津玄師"
          - id: artist_002
            name: "あいみょん"
        """
        let artists = try ArtistsConfigLoader.load(yaml: yaml)
        #expect(artists == [
            ArtistProfile(id: "artist_001", name: "米津玄師"),
            ArtistProfile(id: "artist_002", name: "あいみょん"),
        ])
    }

    @Test("壊れている: name 欠落 / id 重複 / name 重複は throw")
    func malformedThrows() {
        #expect(throws: ConfigError.self) {
            try ArtistsConfigLoader.load(yaml: "artists:\n  - id: a1\n")   // name なし
        }
        #expect(throws: ConfigError.self) {
            try ArtistsConfigLoader.load(yaml: """
            artists:
              - id: a1
                name: "X"
              - id: a1
                name: "Y"
            """)   // id 重複
        }
        #expect(throws: ConfigError.self) {
            try ArtistsConfigLoader.load(yaml: """
            artists:
              - id: a1
                name: "米津玄師"
              - id: a2
                name: "米津玄師"
            """)   // name 重複
        }
    }

    @Test("ファイルが無いのは正常（出荷時は空＝未生成）")
    func missingFileIsEmpty() throws {
        #expect(try ArtistsConfigLoader.load(path: "/no/such/artists.yaml") == [])
    }
}
