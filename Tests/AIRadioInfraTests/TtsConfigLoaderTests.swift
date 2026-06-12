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
        #expect(config.playbackVolume == 1.0)  // 省略時はフル音量
    }

    @Test func loadsPlaybackVolume() throws {
        let yaml = """
        voicevox:
          endpoint: "http://127.0.0.1:50021/"
        playback_volume: 0.65
        """
        #expect(try TtsConfigLoader.load(yaml: yaml).playbackVolume == 0.65)
    }

    @Test func clampsPlaybackVolume() throws {
        let base = "voicevox:\n  endpoint: \"http://x/\"\n"
        #expect(try TtsConfigLoader.load(yaml: base + "playback_volume: 1.5").playbackVolume == 1.0)
        #expect(try TtsConfigLoader.load(yaml: base + "playback_volume: -0.5").playbackVolume == 0.0)
    }

    @Test func loadsAndClampsSpeedScale() throws {
        let base = "voicevox:\n  endpoint: \"http://x/\"\n"
        #expect(try TtsConfigLoader.load(yaml: base).speedScale == 1.0)  // 省略時は標準速
        #expect(try TtsConfigLoader.load(yaml: base + "speed_scale: 1.15").speedScale == 1.15)
        #expect(try TtsConfigLoader.load(yaml: base + "speed_scale: 5.0").speedScale == 2.0)
        #expect(try TtsConfigLoader.load(yaml: base + "speed_scale: 0.1").speedScale == 0.5)
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
