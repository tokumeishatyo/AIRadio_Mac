import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

struct JmaWeatherSourceTests {
    private static let json = Data(#"""
    [
      {
        "publishingOffice": "気象庁",
        "reportDatetime": "2026-06-07T11:00:00+09:00",
        "timeSeries": [
          {
            "timeDefines": ["2026-06-07T11:00:00+09:00"],
            "areas": [
              { "area": {"name":"東京地方","code":"130010"}, "weathers": ["くもり　夕方　から　雨","雨","くもり"] },
              { "area": {"name":"伊豆諸島北部","code":"130020"}, "weathers": ["晴れ"] }
            ]
          }
        ]
      }
    ]
    """#.utf8)

    @Test func extractsTodayWeatherForAreaAndNormalizes() async throws {
        let fake = FakeHTTPClient { _ in Self.json }
        let source = JmaWeatherSource(areaCode: "130000", areaName: "東京地方", http: fake)
        let text = try await source.fetch()

        #expect(text.contains("東京地方"))
        #expect(text.contains("くもり夕方から雨"))  // 全角空白が除去されている
        #expect(!text.contains("\u{3000}"))
    }

    @Test func normalizeRemovesIdeographicSpace() {
        #expect(JmaWeatherSource.normalize("くもり　のち　晴れ") == "くもりのち晴れ")
    }

    @Test func fetchFailureThrowsWeatherError() async {
        let fake = FakeHTTPClient { _ in throw HTTPClientError.status(404) }
        let source = JmaWeatherSource(areaCode: "999999", areaName: "x", http: fake)
        await #expect(throws: ResearchError.self) { _ = try await source.fetch() }
    }
}
