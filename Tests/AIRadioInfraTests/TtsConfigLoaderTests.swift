import Testing
import AIRadioCore
@testable import AIRadioInfra

struct TtsConfigLoaderTests {
    @Test func loadsValidYaml() throws {
        let yaml = """
        voicevox:
          endpoint: "http://127.0.0.1:50021/"
          credit: "VOICEVOX:{speaker}"
        """
        let config = try TtsConfigLoader.load(yaml: yaml)
        #expect(config.endpoint == "http://127.0.0.1:50021/")
        #expect(config.credit == "VOICEVOX:{speaker}")
    }

    @Test func missingEndpointThrowsConfigError() {
        let yaml = """
        voicevox:
          credit: "VOICEVOX:{speaker}"
        """
        #expect(throws: ConfigError.missingField("voicevox.endpoint")) {
            try TtsConfigLoader.load(yaml: yaml)
        }
    }

    @Test func missingVoicevoxSectionThrowsConfigError() {
        #expect(throws: ConfigError.missingField("voicevox.endpoint")) {
            try TtsConfigLoader.load(yaml: "other: 1")
        }
    }
}
