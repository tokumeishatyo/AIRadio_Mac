import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

struct NewsRssSourceTests {
    private static let rss = Data(#"""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel>
    <title>Google ニュース</title>
    <item><title>関東甲信が梅雨入り - tenki.jp</title><link>https://x</link></item>
    <item><title>京都で行方不明のニュース - FNNプライムオンライン</title></item>
    <item><title>速報 - 自転車 - 読売新聞</title></item>
    </channel></rss>
    """#.utf8)

    @Test func parsesItemTitlesStripsSourceAndExcludesChannelTitle() async throws {
        let fake = FakeHTTPClient { _ in Self.rss }
        let source = NewsRssSource(url: "https://news.google.com/rss", maxItems: 5, http: fake)
        let text = try await source.fetch()

        #expect(text.contains("関東甲信が梅雨入り"))
        #expect(text.contains("京都で行方不明のニュース"))
        #expect(!text.contains("tenki.jp"))          // メディア名は除去
        #expect(!text.contains("Google ニュース"))    // チャンネルタイトルは除外
        #expect(text.contains("速報 - 自転車"))        // 見出し内の " - " は保持（末尾のみ除去）
    }

    @Test func limitsToMaxItems() async throws {
        let fake = FakeHTTPClient { _ in Self.rss }
        let source = NewsRssSource(url: "https://x", maxItems: 1, http: fake)
        let text = try await source.fetch()
        #expect(text.contains("関東甲信が梅雨入り"))
        #expect(!text.contains("京都で行方不明"))
    }

    @Test func cleanTitleStripsTrailingSource() {
        #expect(NewsRssSource.cleanTitle("見出し - メディア") == "見出し")
        #expect(NewsRssSource.cleanTitle("A - B - メディア") == "A - B")
        #expect(NewsRssSource.cleanTitle("単独見出し") == "単独見出し")
    }

    @Test func fetchFailureThrowsNewsError() async {
        let fake = FakeHTTPClient { _ in throw HTTPClientError.status(500) }
        let source = NewsRssSource(url: "https://x", maxItems: 5, http: fake)
        await #expect(throws: ResearchError.self) { _ = try await source.fetch() }
    }
}
