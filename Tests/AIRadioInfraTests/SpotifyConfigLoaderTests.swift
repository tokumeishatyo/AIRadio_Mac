import Testing
import AIRadioCore
@testable import AIRadioInfra

struct SpotifyConfigLoaderTests {
    @Test func loadsValidYaml() throws {
        let yaml = """
        spotify:
          client_id: "ID123"
          redirect_uri: "http://127.0.0.1:5543/callback"
          market: "JP"
        """
        let config = try SpotifyConfigLoader.load(yaml: yaml)
        #expect(config.clientId == "ID123")
        #expect(config.redirectUri == "http://127.0.0.1:5543/callback")
        #expect(config.market == "JP")
        #expect(config.loopbackPort == 5543)
    }

    @Test func defaultsRedirectAndMarket() throws {
        let yaml = """
        spotify:
          client_id: "ID123"
        """
        let config = try SpotifyConfigLoader.load(yaml: yaml)
        #expect(config.redirectUri == "http://127.0.0.1:5543/callback")
        #expect(config.market == "JP")
        #expect(config.loopbackPort == 5543)
    }

    @Test func derivesLoopbackPortFromRedirect() throws {
        let yaml = """
        spotify:
          client_id: "ID123"
          redirect_uri: "http://127.0.0.1:8080/callback"
        """
        let config = try SpotifyConfigLoader.load(yaml: yaml)
        #expect(config.loopbackPort == 8080)
    }

    @Test func missingClientIdThrows() {
        #expect(throws: ConfigError.missingField("spotify.client_id")) {
            try SpotifyConfigLoader.load(yaml: "spotify:\n  market: \"JP\"")
        }
    }
}
