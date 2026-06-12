import Foundation
import AIRadioCore

/// ニュース原稿の生成（S11）: 素材取得 → LLM でアナウンサー本文を生成 → 固定イントロ/アウトロと組み立て。
/// fail-tolerant: 素材の個別失敗はフォールバック文言、**LLM 失敗時は定型テンプレ原稿**に倒して放送継続。
public struct LlmNewsScriptProvider: AnnouncementProviding {
    private let news: any ResearchSource
    private let weather: any ResearchSource
    private let llm: any LLMBackend
    private let persona: String
    private let style: NewsScriptStyle
    /// LLM 失敗時の定型原稿（`{news}` / `{weather}` を展開、S5 の announcement_template）。
    private let fallbackTemplate: String
    private let newsFallback: String
    private let weatherFallback: String

    public init(
        news: any ResearchSource,
        weather: any ResearchSource,
        llm: any LLMBackend,
        persona: String,
        style: NewsScriptStyle,
        fallbackTemplate: String,
        newsFallback: String = "本日のニュースは準備中です。",
        weatherFallback: String = "天気予報は準備中です。"
    ) {
        self.news = news
        self.weather = weather
        self.llm = llm
        self.persona = persona
        self.style = style
        self.fallbackTemplate = fallbackTemplate
        self.newsFallback = newsFallback
        self.weatherFallback = weatherFallback
    }

    public func announcement() async -> String {
        let newsText = (try? await news.fetch()) ?? newsFallback
        let weatherText = (try? await weather.fetch()) ?? weatherFallback
        do {
            let raw = try await llm.generate(NewsScriptGenerator.makeRequest(
                news: newsText,
                weather: weatherText,
                persona: persona,
                targetCharacters: style.targetCharacters,
                styleHint: style.styleHint
            ))
            let body = try NewsScriptGenerator.sanitize(raw)
            return "\(style.intro) \(body) \(style.outro)"
        } catch {
            // LLM 不調でも放送は止めない（定型テンプレ原稿に倒す）。
            return TemplateExpander.expand(
                fallbackTemplate,
                values: ["news": newsText, "weather": weatherText]
            )
        }
    }
}
