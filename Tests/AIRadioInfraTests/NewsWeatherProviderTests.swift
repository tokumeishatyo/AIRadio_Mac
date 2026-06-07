import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

private struct StubSource: ResearchSource {
    let result: Result<String, Error>
    func fetch() async throws -> String {
        switch result {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }
}

struct NewsWeatherProviderTests {
    @Test func composesNewsAndWeatherIntoTemplate() async {
        let provider = NewsWeatherProvider(
            news: StubSource(result: .success("ニュース本文。")),
            weather: StubSource(result: .success("天気本文。")),
            template: "ニュース: {news} 天気: {weather}"
        )
        let text = await provider.announcement()
        #expect(text == "ニュース: ニュース本文。 天気: 天気本文。")
    }

    @Test func usesFallbacksWhenFetchFails() async {
        let provider = NewsWeatherProvider(
            news: StubSource(result: .failure(ResearchError.newsFetchFailed("x"))),
            weather: StubSource(result: .failure(ResearchError.weatherFetchFailed("y"))),
            template: "{news}|{weather}",
            newsFallback: "NEWS_NG",
            weatherFallback: "WX_NG"
        )
        let text = await provider.announcement()
        #expect(text == "NEWS_NG|WX_NG")  // fail-tolerant
    }
}
