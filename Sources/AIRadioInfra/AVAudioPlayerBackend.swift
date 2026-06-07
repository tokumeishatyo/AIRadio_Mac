import Foundation
import AVFoundation
import AIRadioCore

/// `AVAudioPlayer` による WAV 再生。再生完了まで待機し、キャンセル時は停止する。
public final class AVAudioPlayerBackend: AudioPlayer, @unchecked Sendable {
    public init() {}

    public func play(_ wav: Data) async throws {
        let player = try AVAudioPlayer(data: wav)
        let duration = player.duration
        guard player.play() else {
            throw AudioError.playbackFailed
        }
        do {
            // 再生時間 + 余韻ぶん待機（FakeClock を使わない実再生のため実時間）。
            try await Task.sleep(nanoseconds: UInt64((duration + 0.2) * 1_000_000_000))
        } catch {
            player.stop()          // キャンセル時は即停止（完全静寂）
            throw error
        }
        player.stop()
    }
}
