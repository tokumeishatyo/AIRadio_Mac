import Testing
import AIRadioCore
@testable import AIRadioInfra

struct ResearchConfigLoaderTests {
    @Test func loadsValidYaml() throws {
        let yaml = """
        news:
          rss_url: "https://news.google.com/rss?hl=ja"
          max_items: 3
        weather:
          area_code: "130000"
          area_name: "東京地方"
        announcement_template: "N:{news} W:{weather}"
        """
        let config = try ResearchConfigLoader.load(yaml: yaml)
        #expect(config.newsRssUrl == "https://news.google.com/rss?hl=ja")
        #expect(config.newsMaxItems == 3)
        #expect(config.weatherAreaCode == "130000")
        #expect(config.weatherAreaName == "東京地方")
        #expect(config.announcementTemplate == "N:{news} W:{weather}")
    }

    @Test func appliesDefaults() throws {
        let yaml = """
        weather:
          area_code: "270000"
          area_name: "大阪府"
        """
        let config = try ResearchConfigLoader.load(yaml: yaml)
        #expect(config.newsMaxItems == 5)
        #expect(config.newsRssUrl.contains("news.google.com"))
        #expect(config.announcementTemplate.contains("{news}"))
    }

    @Test func missingAreaCodeThrows() {
        #expect(throws: ConfigError.missingField("weather.area_code")) {
            try ResearchConfigLoader.load(yaml: "news:\n  max_items: 3")
        }
    }

    @Test func loadsLlmScriptSection() throws {
        let yaml = """
        weather:
          area_code: "130000"
        llm_script:
          style_hint: "簡潔に"
          target_minutes: 3
          chars_per_minute: 300
          intro: "ニュースです。"
          outro: "おしまい。"
        """
        let style = try ResearchConfigLoader.load(yaml: yaml).llmScript
        #expect(style == NewsScriptStyle(
            styleHint: "簡潔に", targetMinutes: 3, charsPerMinute: 300,
            intro: "ニュースです。", outro: "おしまい。"))
        #expect(style.targetCharacters == 900)
    }

    @Test func llmScriptDefaultsWhenOmitted() throws {
        let style = try ResearchConfigLoader.load(yaml: "weather:\n  area_code: \"130000\"\n").llmScript
        #expect(style == NewsScriptStyle())
        #expect(style.intro.contains("{hour12}"))
        #expect(style.targetCharacters == 640)
    }
}
