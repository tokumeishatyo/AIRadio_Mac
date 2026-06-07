import Testing
@testable import AIRadioCore

struct ErrorsTests {
    @Test func spotifyErrorCodes() {
        #expect(SpotifyError.noDevice.code == "E-SPT-NO-DEVICE-001")
        #expect(SpotifyError.apiFailed("x").code == "E-SPT-API-FAILED-001")
    }

    @Test func configErrorCode() {
        #expect(ConfigError.missingField("track_uri").code == "E-CFG-MISSING-FIELD-001")
    }

    @Test func messageIncludesDetail() {
        #expect(SpotifyError.apiFailed("timeout").message.contains("timeout"))
        #expect(ConfigError.missingField("track_uri").message.contains("track_uri"))
    }
}
