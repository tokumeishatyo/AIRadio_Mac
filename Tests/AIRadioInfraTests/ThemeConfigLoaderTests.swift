import Testing
import AIRadioCore
@testable import AIRadioInfra

struct ThemeConfigLoaderTests {
    private let validYaml = """
    opening:
      tagline: "T"
      track_uri: "https://open.spotify.com/track/ABC?si=1"
      intro_seconds: 5
      volume: 80
      ducked_volume: 30
      outro_seconds: 10
      announcement: "OP本文"
    news:
      tagline: "ニュース"
      track_uri: "spotify:track:NEWS"
      announcement: "ニュース本文"
    ending:
      track_uri: "spotify:track:ED"
      announcement: "ED本文"
    """

    @Test func loadsGreetings() throws {
        let yaml = validYaml + """

        greetings:
          morning: "おはようなのだ"
          afternoon: "こんにちはなのだ"
          evening: "こんばんはなのだ"
        """
        let themes = try ThemeConfigLoader.load(yaml: yaml)
        #expect(themes.greetings == Greetings(
            morning: "おはようなのだ", afternoon: "こんにちはなのだ", evening: "こんばんはなのだ"))
    }

    @Test func greetingsDefaultWhenOmitted() throws {
        let themes = try ThemeConfigLoader.load(yaml: validYaml)
        #expect(themes.greetings == Greetings())  // おはようございます / こんにちは / こんばんは
    }

    @Test func loadsAndNormalizesOpening() throws {
        let themes = try ThemeConfigLoader.load(yaml: validYaml)
        #expect(themes.opening.theme.trackUri == "spotify:track:ABC")  // 共有 URL を正規化
        #expect(themes.opening.theme.tagline == "T")
        #expect(themes.opening.theme.duckedVolume == 30)
        #expect(themes.opening.theme.outroSeconds == 10)
        #expect(themes.opening.announcement == "OP本文")
    }

    @Test func endingHasNoTagline() throws {
        let themes = try ThemeConfigLoader.load(yaml: validYaml)
        #expect(themes.ending.theme.tagline == nil)
        #expect(themes.ending.theme.trackUri == "spotify:track:ED")
    }

    @Test func appliesDefaultsForMissingNumbers() throws {
        let themes = try ThemeConfigLoader.load(yaml: validYaml)
        // news は数値未指定 → デフォルト適用
        #expect(themes.news.theme.volume == 85)
        #expect(themes.news.theme.duckedVolume == 35)
        #expect(themes.news.theme.introSeconds == 5)
        #expect(themes.news.theme.outroSeconds == 15)
    }

    @Test func missingTrackUriThrows() {
        let yaml = """
        opening:
          announcement: "x"
        news:
          track_uri: "a"
        ending:
          track_uri: "b"
        """
        #expect(throws: ConfigError.missingField("opening.track_uri")) {
            try ThemeConfigLoader.load(yaml: yaml)
        }
    }

    @Test func missingSectionThrows() {
        let yaml = """
        opening:
          track_uri: "a"
        ending:
          track_uri: "b"
        """
        #expect(throws: ConfigError.missingField("news")) {
            try ThemeConfigLoader.load(yaml: yaml)
        }
    }
}
