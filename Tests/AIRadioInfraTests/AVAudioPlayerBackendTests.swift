import Testing
import Foundation
@testable import AIRadioInfra

struct AVAudioPlayerBackendTests {
    @Test func invalidWavDataThrows() async {
        let player = AVAudioPlayerBackend()
        await #expect(throws: (any Error).self) {
            try await player.play(Data([0x00, 0x01, 0x02, 0x03, 0x04]))
        }
    }

    @Test func clampsVolume() {
        #expect(AVAudioPlayerBackend().volume == 1.0)
        #expect(AVAudioPlayerBackend(volume: 0.65).volume == 0.65)
        #expect(AVAudioPlayerBackend(volume: 1.5).volume == 1.0)
        #expect(AVAudioPlayerBackend(volume: -0.5).volume == 0.0)
    }
}
