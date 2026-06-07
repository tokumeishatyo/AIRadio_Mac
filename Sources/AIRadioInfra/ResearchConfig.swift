import Foundation
import Yams
import AIRadioCore

/// ニュース・天気のリサーチ設定。
public struct ResearchConfig: Sendable, Equatable {
    public var newsRssUrl: String
    public var newsMaxItems: Int
    public var weatherAreaCode: String
    public var weatherAreaName: String
    public var announcementTemplate: String

    public init(
        newsRssUrl: String,
        newsMaxItems: Int,
        weatherAreaCode: String,
        weatherAreaName: String,
        announcementTemplate: String
    ) {
        self.newsRssUrl = newsRssUrl
        self.newsMaxItems = newsMaxItems
        self.weatherAreaCode = weatherAreaCode
        self.weatherAreaName = weatherAreaName
        self.announcementTemplate = announcementTemplate
    }
}

/// `config/research.yaml` のローダ。
public enum ResearchConfigLoader {
    private struct File: Decodable {
        struct News: Decodable {
            let rss_url: String?
            let max_items: Int?
        }
        struct Weather: Decodable {
            let area_code: String?
            let area_name: String?
        }
        let news: News?
        let weather: Weather?
        let announcement_template: String?
    }

    private static let defaultTemplate =
        "本日のニュースをお伝えします。{news} 続いて天気予報です。{weather} 以上、ニュースと天気でした。"

    public static func load(yaml: String) throws -> ResearchConfig {
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        guard let areaCode = file.weather?.area_code, !areaCode.isEmpty else {
            throw ConfigError.missingField("weather.area_code")
        }
        return ResearchConfig(
            newsRssUrl: file.news?.rss_url ?? "https://news.google.com/rss?hl=ja&gl=JP&ceid=JP:ja",
            newsMaxItems: file.news?.max_items ?? 5,
            weatherAreaCode: areaCode,
            weatherAreaName: file.weather?.area_name ?? "対象地域",
            announcementTemplate: file.announcement_template ?? defaultTemplate
        )
    }

    public static func load(path: String) throws -> ResearchConfig {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }
}
