import Testing
import Foundation
import AIRadioInfra

struct AVAudioPlayerBackendTests {
    @Test func invalidWavDataThrows() async {
        let player = AVAudioPlayerBackend()
        await #expect(throws: (any Error).self) {
            try await player.play(Data([0x00, 0x01, 0x02, 0x03, 0x04]))
        }
    }
}
