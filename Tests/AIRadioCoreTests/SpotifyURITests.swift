import Testing
import AIRadioCore

struct SpotifyURITests {
    @Test func normalizesAllFormats() {
        #expect(SpotifyURI.normalizeTrack("spotify:track:ABC") == "spotify:track:ABC")
        #expect(SpotifyURI.normalizeTrack("https://open.spotify.com/track/ABC?si=xyz") == "spotify:track:ABC")
        #expect(SpotifyURI.normalizeTrack("https://open.spotify.com/intl-ja/track/ABC") == "spotify:track:ABC")
        #expect(SpotifyURI.normalizeTrack("ABC") == "spotify:track:ABC")
    }

    @Test func extractsTrackId() {
        #expect(SpotifyURI.trackId(from: "spotify:track:XYZ") == "XYZ")
        #expect(SpotifyURI.trackId(from: "https://open.spotify.com/track/XYZ?si=1") == "XYZ")
    }
}
