import Foundation
import Yams
import AIRadioCore

/// LLM ニュース原稿の語り設定（S11）。
public struct NewsScriptStyle: Sendable, Equatable {
    public var styleHint: String
    public var targetMinutes: Int
    public var charsPerMinute: Int
    /// 固定の時報イントロ（時刻プレースホルダは発話直前に展開される）。
    public var intro: String
    /// 固定の締め。
    public var outro: String

    public init(
        styleHint: String = "",
        targetMinutes: Int = 2,
        charsPerMinute: Int = 320,
        intro: String = "時刻は{hour12}時{minute}分になりました。ニュースの時間です。",
        outro: String = "以上、ニュースと天気予報でした。"
    ) {
        self.styleHint = styleHint
        self.targetMinutes = targetMinutes
        self.charsPerMinute = charsPerMinute
        self.intro = intro
        self.outro = outro
    }

    public var targetCharacters: Int {
        targetMinutes * charsPerMinute
    }
}

/// ニュース・天気のリサーチ設定。
public struct ResearchConfig: Sendable, Equatable {
    public var newsRssUrl: String
    public var newsMaxItems: Int
    public var weatherAreaCode: String
    public var weatherAreaName: String
    public var announcementTemplate: String
    public var llmScript: NewsScriptStyle

    public init(
        newsRssUrl: String,
        newsMaxItems: Int,
        weatherAreaCode: String,
        weatherAreaName: String,
        announcementTemplate: String,
        llmScript: NewsScriptStyle = NewsScriptStyle()
    ) {
        self.newsRssUrl = newsRssUrl
        self.newsMaxItems = newsMaxItems
        self.weatherAreaCode = weatherAreaCode
        self.weatherAreaName = weatherAreaName
        self.announcementTemplate = announcementTemplate
        self.llmScript = llmScript
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
        struct LlmScript: Decodable {
            let style_hint: String?
            let target_minutes: Int?
            let chars_per_minute: Int?
            let intro: String?
            let outro: String?
        }
        let news: News?
        let weather: Weather?
        let announcement_template: String?
        let llm_script: LlmScript?
    }

    private static let defaultTemplate =
        "本日のニュースをお伝えします。{news} 続いて天気予報です。{weather} 以上、ニュースと天気でした。"

    public static func load(yaml: String) throws -> ResearchConfig {
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        guard let areaCode = file.weather?.area_code, !areaCode.isEmpty else {
            throw ConfigError.missingField("weather.area_code")
        }
        let defaults = NewsScriptStyle()
        return ResearchConfig(
            newsRssUrl: file.news?.rss_url ?? "https://news.google.com/rss?hl=ja&gl=JP&ceid=JP:ja",
            newsMaxItems: file.news?.max_items ?? 5,
            weatherAreaCode: areaCode,
            weatherAreaName: file.weather?.area_name ?? "対象地域",
            announcementTemplate: file.announcement_template ?? defaultTemplate,
            llmScript: NewsScriptStyle(
                styleHint: file.llm_script?.style_hint ?? defaults.styleHint,
                targetMinutes: file.llm_script?.target_minutes ?? defaults.targetMinutes,
                charsPerMinute: file.llm_script?.chars_per_minute ?? defaults.charsPerMinute,
                intro: file.llm_script?.intro ?? defaults.intro,
                outro: file.llm_script?.outro ?? defaults.outro
            )
        )
    }

    public static func load(path: String) throws -> ResearchConfig {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }
}
