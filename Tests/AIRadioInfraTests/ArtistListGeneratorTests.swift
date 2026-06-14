import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

struct ArtistListGeneratorTests {
    // MARK: parseEntries（逸脱耐性が核。仕様 s19b §3.3）

    @Test("名前 + タブ + カタカナ読み → 両方取得")
    func nameAndReading() {
        let r = ArtistListGenerator.parseEntries("米津玄師\tヨネヅケンシ")
        #expect(r.count == 1)
        #expect(r[0].name == "米津玄師")
        #expect(r[0].reading == "ヨネヅケンシ")
    }

    @Test("タブ無し → 名前のみで救済（reading=nil、退行なし）")
    func nameOnly() {
        let r = ArtistListGenerator.parseEntries("あいみょん")
        #expect(r[0].name == "あいみょん")
        #expect(r[0].reading == nil)
    }

    @Test("bullet/番号付き → 除去して名前・読みを取得")
    func bulletsStripped() {
        let r = ArtistListGenerator.parseEntries("- 1. サザンオールスターズ\tサザンオールスターズ")
        #expect(r[0].name == "サザンオールスターズ")
        #expect(r[0].reading == "サザンオールスターズ")
    }

    @Test("半角カナ読み → NFKC で全角化")
    func halfWidthReading() {
        let r = ArtistListGenerator.parseEntries("A\tｱｲﾐｮﾝ")
        #expect(r[0].reading == "アイミョン")
    }

    @Test("非カタカナ読み（ひらがな/英字/「不明」）→ reading=nil で捨てる")
    func nonKatakanaReadingDropped() {
        #expect(ArtistListGenerator.parseEntries("X\tえっくす")[0].reading == nil)
        #expect(ArtistListGenerator.parseEntries("Y\tYomi")[0].reading == nil)
        #expect(ArtistListGenerator.parseEntries("Z\t不明")[0].reading == nil)
    }

    @Test("タブ複数 → 2 列目のみを読みにする")
    func multipleTabs() {
        let r = ArtistListGenerator.parseEntries("name\tヨミ\textra")
        #expect(r[0].name == "name")
        #expect(r[0].reading == "ヨミ")
    }

    @Test("空名（タブ始まり）→ スキップ")
    func emptyNameSkipped() {
        #expect(ArtistListGenerator.parseEntries("\tヨミ").isEmpty)
    }

    @Test("複数行: 読みあり/なし混在をまとめてパース")
    func multiline() {
        let r = ArtistListGenerator.parseEntries("米津玄師\tヨネヅケンシ\nあいみょん\nBUMP\tバンプ")
        #expect(r.map { $0.name } == ["米津玄師", "あいみょん", "BUMP"])
        #expect(r.map { $0.reading } == ["ヨネヅケンシ", nil, "バンプ"])
    }

    // MARK: write（reading 非 nil のみ出力）

    @Test("write: reading は非 nil のみ出力、nil は出力しない（load 往復）")
    func writeRoundTrip() throws {
        let path = NSTemporaryDirectory() + "s19b-artists-\(UUID().uuidString).yaml"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try ArtistListGenerator.write([
            ArtistProfile(id: "artist_001", name: "米津玄師", reading: "ヨネヅケンシ"),
            ArtistProfile(id: "artist_002", name: "あいみょん"),   // reading nil
        ], to: path)
        // Yams は日本語を \uXXXX でエスケープして書く（name も同様・S15 から既存挙動）が、デコードは正しく戻る。
        // よって生テキストの literal 一致ではなく「reading キーが 1 回だけ（nil は出力しない）」＋ load 往復で検証する。
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        #expect(yaml.components(separatedBy: "reading:").count - 1 == 1)   // reading キーは 1 回だけ
        #expect(try ArtistsConfigLoader.load(path: path) == [
            ArtistProfile(id: "artist_001", name: "米津玄師", reading: "ヨネヅケンシ"),
            ArtistProfile(id: "artist_002", name: "あいみょん", reading: nil),
        ])
    }
}
