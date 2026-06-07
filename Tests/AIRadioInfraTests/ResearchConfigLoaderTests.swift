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
}
