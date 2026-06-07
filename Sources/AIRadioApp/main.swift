import Foundation
import AIRadioCore
import AIRadioInfra

// デモエントリ。メニューバー UI と放送エンジンは後続スライス（S7 / S4 以降）で実装する。
//   AIRADIO_DEMO=tts          （既定）VOICEVOX 合成 + 再生
//   AIRADIO_DEMO=spotify-auth  Spotify ログイン（PKCE、ブラウザ、初回のみ）
//   AIRADIO_DEMO=spotify       Spotify 検索 + Web API 再生
//   AIRADIO_DEMO=theme         統一テーマエンジン（OP / ニュース / ED）

private let spotifyScopes = ["user-read-playback-state", "user-modify-playback-state"]

private func makeSpotifyAuth() throws -> SpotifyAuth {
    let config = try SpotifyConfigLoader.load(path: "config/spotify.local.yaml")
    return SpotifyAuth(
        clientId: config.clientId,
        redirectUri: config.redirectUri,
        loopbackPort: config.loopbackPort,
        scopes: spotifyScopes,
        store: KeychainTokenStore(),
        http: URLSessionHTTPClient(),
        clock: SystemClock()
    )
}

func runTtsDemo() async {
    print("ケイラボAIラジオ Mac版 — TTS デモ（VOICEVOX）")
    do {
        let config = try TtsConfigLoader.load(path: "config/tts.yaml")
        let tts = VoicevoxTTS(endpoint: config.endpoint, http: URLSessionHTTPClient())
        let wav = try await tts.synthesize(text: "こんにちは。ケイラボAIラジオのテストなのだ。", speakerId: 3)
        print("合成成功: \(wav.count) bytes")
        try await AVAudioPlayerBackend().play(wav)
        print("再生完了")
    } catch let error as RadioError {
        print("エラー[\(error.code)]: \(error.message)")
    } catch {
        print("エラー: \(error)")
    }
}

func runSpotifyAuthDemo() async {
    print("ケイラボAIラジオ Mac版 — Spotify ログイン（PKCE）")
    do {
        let auth = try makeSpotifyAuth()
        print("ブラウザで Spotify にログイン・許可してください…")
        try await auth.authorize()
        print("認証完了。refresh トークンを Keychain に保存しました。")
    } catch let error as RadioError {
        print("エラー[\(error.code)]: \(error.message)")
    } catch {
        print("エラー: \(error)")
    }
}

func runSpotifyDemo() async {
    print("ケイラボAIラジオ Mac版 — Spotify デモ（検索 + Web API 再生）")
    do {
        let config = try SpotifyConfigLoader.load(path: "config/spotify.local.yaml")
        let auth = try makeSpotifyAuth()
        let http = URLSessionHTTPClient()
        let searcher = SpotifyWebSearcher(auth: auth, market: config.market, http: http)
        let controller = WebApiSpotifyController(auth: auth, http: http)

        let results = try await searcher.search(query: "YOASOBI アイドル", limit: 3)
        print("検索結果 \(results.count) 件:")
        for track in results {
            print("  - \(track.artist) / \(track.title)  \(track.uri)")
        }
        guard let first = results.first else { print("結果なし"); return }

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

func runThemeDemo() async {
    print("ケイラボAIラジオ Mac版 — 統一テーマエンジン デモ（OP / ニュース / ED）")
    do {
        let themes = try ThemeConfigLoader.load(path: "config/themes.yaml")
        let ttsConfig = try TtsConfigLoader.load(path: "config/tts.yaml")
        let http = URLSessionHTTPClient()
        let auth = try makeSpotifyAuth()
        let sequencer = ThemeSequencer(
            tts: VoicevoxTTS(endpoint: ttsConfig.endpoint, http: http),
            audio: AVAudioPlayerBackend(),
            spotify: WebApiSpotifyController(auth: auth, http: http),
            clock: SystemClock()
        )
        let speakerId = 3  // ずんだもん
        let segments: [(String, LoadedTheme)] = [
            ("オープニング", themes.opening),
            ("ニュースと天気", themes.news),
            ("エンディング", themes.ending),
        ]
        for (name, segment) in segments {
            print("=== \(name) ===")
            try await sequencer.run(theme: segment.theme, announcement: segment.announcement, speakerId: speakerId)
            print("\(name) 完了")
        }
        print("デモ完了")
    } catch let error as RadioError {
        print("エラー[\(error.code)]: \(error.message)")
    } catch {
        print("エラー: \(error)")
    }
}

switch ProcessInfo.processInfo.environment["AIRADIO_DEMO"] ?? "tts" {
case "spotify-auth": await runSpotifyAuthDemo()
case "spotify": await runSpotifyDemo()
case "theme": await runThemeDemo()
default: await runTtsDemo()
}
