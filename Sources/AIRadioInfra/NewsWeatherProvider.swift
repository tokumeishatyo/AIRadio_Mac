import Foundation
import AIRadioCore

/// ニュースと天気を取得し、テンプレートに展開してニュース原稿を生成する（fail-tolerant）。
public struct NewsWeatherProvider: AnnouncementProviding {
    private let news: any ResearchSource
    private let weather: any ResearchSource
    private let template: String
    private let newsFallback: String
    private let weatherFallback: String

    public init(
        news: any ResearchSource,
        weather: any ResearchSource,
        template: String,
        newsFallback: String = "本日のニュースは準備中です。",
        weatherFallback: String = "天気予報は準備中です。"
    ) {
        self.news = news
        self.weather = weather
        self.template = template
        self.newsFallback = newsFallback
        self.weatherFallback = weatherFallback
    }

    /// `{news}` / `{weather}` を実データで展開した原稿を返す。取得失敗時はフォールバック文言。
    public func announcement() async -> String {
        let newsText = (try? await news.fetch()) ?? newsFallback
        let weatherText = (try? await weather.fetch()) ?? weatherFallback
        return TemplateExpander.expand(template, values: ["news": newsText, "weather": weatherText])
    }
}
