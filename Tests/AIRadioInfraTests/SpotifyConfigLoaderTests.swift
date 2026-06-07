import Testing
import AIRadioCore
@testable import AIRadioInfra

struct SpotifyConfigLoaderTests {
    @Test func loadsValidYaml() throws {
        let yaml = """
        spotify:
          client_id: "ID123"
          client_secret: "SECRET456"
          market: "JP"
        """
        let config = try SpotifyConfigLoader.load(yaml: yaml)
        #expect(config.clientId == "ID123")
        #expect(config.clientSecret == "SECRET456")
        #expect(config.market == "JP")
    }

    @Test func defaultsMarketToJP() throws {
        let yaml = """
        spotify:
          client_id: "ID123"
          client_secret: "SECRET456"
        """
        let config = try SpotifyConfigLoader.load(yaml: yaml)
        #expect(config.market == "JP")
    }

    @Test func missingClientIdThrows() {
        let yaml = """
        spotify:
          client_secret: "SECRET456"
        """
        #expect(throws: ConfigError.missingField("spotify.client_id")) {
            try SpotifyConfigLoader.load(yaml: yaml)
        }
    }

    @Test func missingClientSecretThrows() {
        let yaml = """
        spotify:
          client_id: "ID123"
        """
        #expect(throws: ConfigError.missingField("spotify.client_secret")) {
            try SpotifyConfigLoader.load(yaml: yaml)
        }
    }
}
