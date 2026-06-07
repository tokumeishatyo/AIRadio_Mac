import Foundation
import AIRadioCore
import AIRadioInfra

// S1 デモ: VOICEVOX でテストフレーズを合成し再生する（実機聴覚確認用）。
// メニューバー UI と放送エンジンは後続スライス（S7 / S3〜）で実装する。
func runDemo() async {
    print("ケイラボAIラジオ Mac版 — S1 デモ（VOICEVOX TTS + 再生）")
    do {
        let config = try TtsConfigLoader.load(path: "config/tts.yaml")
        print("VOICEVOX endpoint: \(config.endpoint)")

        let tts = VoicevoxTTS(endpoint: config.endpoint, http: URLSessionHTTPClient())
        let text = "こんにちは。ケイラボAIラジオ、マック版のテスト放送なのだ。"
        let wav = try await tts.synthesize(text: text, speakerId: 3)  // 3 = ずんだもん（ノーマル）
        print("合成成功: \(wav.count) bytes")

        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("airadio_s1.wav")
        try wav.write(to: out)
        print("WAV 保存: \(out.path)")

        let player = AVAudioPlayerBackend()
        try await player.play(wav)
        print("再生完了")
    } catch let error as RadioError {
        print("エラー[\(error.code)]: \(error.message)")
    } catch {
        print("エラー: \(error)")
    }
}

await runDemo()
