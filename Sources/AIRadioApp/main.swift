import Foundation
import AIRadioCore
import AIRadioInfra

// デモエントリ。メニューバー UI と放送エンジンは後続スライス（S7 / S3〜）で実装する。
//   AIRADIO_DEMO=tts     （既定）VOICEVOX 合成 + 再生
//   AIRADIO_DEMO=spotify  Spotify 検索 + AppleScript 再生

func runTtsDemo() async {
    print("ケイラボAIラジオ Mac版 — TTS デモ（VOICEVOX）")
    do {
        let config = try TtsConfigLoader.load(path: "config/tts.yaml")
        print("VOICEVOX endpoint: \(config.endpoint)")
        let tts = VoicevoxTTS(endpoint: config.endpoint, http: URLSessionHTTPClient())
        let text = "こんにちは。ケイラボAIラジオ、マック版のテスト放送なのだ。"
        let wav = try await tts.synthesize(text: text, speakerId: 3)  // 3 = ずんだもん
        print("合成成功: \(wav.count) bytes")
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("airadio_s1.wav")
        try wav.write(to: out)
        print("WAV 保存: \(out.path)")
        try await AVAudioPlayerBackend().play(wav)
        print("再生完了")
    } catch let error as RadioError {
        print("エラー[\(error.code)]: \(error.message)")
    } catch {
        print("エラー: \(error)")
    }
}

func runSpotifyDemo() async {
    print("ケイラボAIラジオ Mac版 — Spotify デモ（検索 + AppleScript 再生）")
    do {
        let config = try SpotifyConfigLoader.load(path: "config/spotify.local.yaml")
        let searcher = SpotifyWebSearcher(
            clientId: config.clientId,
            clientSecret: config.clientSecret,
            market: config.market,
            http: URLSessionHTTPClient(),
            clock: SystemClock()
        )
        let results = try await searcher.search(query: "YOASOBI アイドル", limit: 3)
        print("検索結果 \(results.count) 件:")
        for track in results {
            print("  - \(track.artist) / \(track.title)  \(track.uri)  playable=\(track.isPlayable)")
        }
        guard let first = results.first else { print("結果なし"); return }

        let playable = try await searcher.isPlayable(first.uri)
        print("プレフライト: 『\(first.title)』 playable=\(playable)")

        let controller = AppleScriptSpotifyController(runner: OsascriptRunner())
        try await controller.play(uri: first.uri)
        try await controller.setVolume(80)
        print("再生開始（10 秒）…")
        try await SystemClock().sleep(seconds: 10)
        let state = try await controller.playerState()
        print("状態: \(state)")
        try await controller.pause()
        print("停止")
    } catch let error as RadioError {
        print("エラー[\(error.code)]: \(error.message)")
    } catch {
        print("エラー: \(error)")
    }
}

switch ProcessInfo.processInfo.environment["AIRADIO_DEMO"] ?? "tts" {
case "spotify": await runSpotifyDemo()
default: await runTtsDemo()
}
