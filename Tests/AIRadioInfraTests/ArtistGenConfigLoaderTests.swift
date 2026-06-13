import Testing
import Foundation
@testable import AIRadioInfra

struct ArtistGenConfigLoaderTests {
    @Test("空・欠落は既定値（邦楽・100）")
    func defaults() throws {
        let empty = try ArtistGenConfigLoader.load(yaml: "")
        #expect(empty.targetCount == 100)
        #expect(empty.genrePrompt.contains("邦楽"))
        // ファイル無しも既定。
        let missing = try ArtistGenConfigLoader.load(path: "/no/such/artist-gen.yaml")
        #expect(missing == ArtistGenConfig())
    }

    @Test("ジャンル・件数を上書きできる")
    func override() throws {
        let yaml = """
        generation:
          genre_prompt: "海外のポップ/ロックの有名アーティスト（洋楽）中心。"
          target_count: 20
        """
        let config = try ArtistGenConfigLoader.load(yaml: yaml)
        #expect(config.genrePrompt == "海外のポップ/ロックの有名アーティスト（洋楽）中心。")
        #expect(config.targetCount == 20)
    }

    @Test("target_count が 0 以下なら既定にフォールバック")
    func invalidCountFallsBack() throws {
        let config = try ArtistGenConfigLoader.load(yaml: "generation:\n  target_count: 0\n")
        #expect(config.targetCount == 100)
    }
}
