import Testing
import AIRadioCore
@testable import AIRadioInfra

struct ThemeConfigLoaderTests {
    // OP / ED は by_dj（DJ 別固定口上、s13.5）、news は単一。
    private let validYaml = """
    opening:
      track_uri: "https://open.spotify.com/track/ABC?si=1"
      intro_seconds: 5
      volume: 80
      ducked_volume: 30
      outro_seconds: 10
      by_dj:
        zundamon:
          tagline: "ずんT"
          announcement: "OP本文なのだ"
        metan:
          tagline: "めたんT"
          announcement: "OP本文ですわ"
    news:
      tagline: "ニュース"
      track_uri: "spotify:track:NEWS"
      announcement: "ニュース本文"
    ending:
      track_uri: "spotify:track:ED"
      by_dj:
        zundamon:
          announcement: "ED本文なのだ"
        metan:
          announcement: "ED本文ですわ"
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

    @Test func loadsAndNormalizesOpeningPerDj() throws {
        let themes = try ThemeConfigLoader.load(yaml: validYaml)
        // 共有 BGM 演出（staging.tagline は per-DJ のため nil）。
        #expect(themes.opening.staging.trackUri == "spotify:track:ABC")  // 共有 URL を正規化
        #expect(themes.opening.staging.tagline == nil)
        #expect(themes.opening.staging.duckedVolume == 30)
        #expect(themes.opening.staging.outroSeconds == 10)
        // DJ 別口上（tagline + 本文）。
        #expect(themes.opening.byDj["zundamon"] == DjSpiel(tagline: "ずんT", announcement: "OP本文なのだ"))
        #expect(themes.opening.byDj["metan"]?.announcement == "OP本文ですわ")
        #expect(themes.opening.spiel(preferring: "metan")?.tagline == "めたんT")
    }

    @Test func endingPerDjHasNoTagline() throws {
        let themes = try ThemeConfigLoader.load(yaml: validYaml)
        #expect(themes.ending.staging.tagline == nil)
        #expect(themes.ending.staging.trackUri == "spotify:track:ED")
        #expect(themes.ending.byDj["zundamon"]?.announcement == "ED本文なのだ")
        #expect(themes.ending.byDj["zundamon"]?.tagline == nil)
    }

    @Test func newsStaysSingleWithTagline() throws {
        let themes = try ThemeConfigLoader.load(yaml: validYaml)
        #expect(themes.news.theme.tagline == "ニュース")
        #expect(themes.news.announcement == "ニュース本文")
        // news は数値未指定 → デフォルト適用
        #expect(themes.news.theme.volume == 85)
        #expect(themes.news.theme.duckedVolume == 35)
        #expect(themes.news.theme.introSeconds == 5)
        #expect(themes.news.theme.outroSeconds == 15)
    }

    @Test func spielFallsBackWhenMainMissing() throws {
        let themes = try ThemeConfigLoader.load(yaml: validYaml)
        // tsumugi は未定義 → fallbacks（zundamon）→ それも無ければ任意。
        #expect(themes.opening.spiel(preferring: "tsumugi", fallbacks: ["zundamon"])?.announcement == "OP本文なのだ")
        #expect(themes.opening.spiel(preferring: "unknown") != nil)  // 任意の 1 件
    }

    @Test func missingTrackUriThrows() {
        let yaml = """
        opening:
          by_dj:
            zundamon: { announcement: "x" }
        news:
          track_uri: "a"
        ending:
          track_uri: "b"
          by_dj:
            zundamon: { announcement: "y" }
        """
        #expect(throws: ConfigError.missingField("opening.track_uri")) {
            try ThemeConfigLoader.load(yaml: yaml)
        }
    }

    @Test func missingByDjThrows() {
        let yaml = """
        opening:
          track_uri: "a"
        news:
          track_uri: "n"
        ending:
          track_uri: "b"
          by_dj:
            zundamon: { announcement: "y" }
        """
        #expect(throws: ConfigError.missingField("opening.by_dj")) {
            try ThemeConfigLoader.load(yaml: yaml)
        }
    }

    @Test func missingSectionThrows() {
        let yaml = """
        opening:
          track_uri: "a"
          by_dj:
            zundamon: { announcement: "x" }
        ending:
          track_uri: "b"
          by_dj:
            zundamon: { announcement: "y" }
        """
        #expect(throws: ConfigError.missingField("news")) {
            try ThemeConfigLoader.load(yaml: yaml)
        }
    }
}
