import Foundation
import AIRadioCore
import AIRadioInfra

// デモエントリ。メニューバー UI と放送エンジンは後続スライス（S7 / S4 以降）で実装する。
//   AIRADIO_DEMO=tts          （既定）VOICEVOX 合成 + 再生
//   AIRADIO_DEMO=spotify-auth  Spotify ログイン（PKCE、ブラウザ、初回のみ）
//   AIRADIO_DEMO=spotify       Spotify 検索 + Web API 再生
//   AIRADIO_DEMO=theme         統一テーマエンジン（OP / ニュース / ED）
//   AIRADIO_DEMO=corner        会話コーナー（LLM 台本 → DJ 二人の会話 → 一曲）
//   AIRADIO_DEMO=broadcast     番組 1 周（OP → トーク → ニュース天気 → ED、Ctrl-C で停止）

// リダイレクト時も進行ログが即時見えるよう、stdout を行バッファリングにする。
setvbuf(stdout, nil, _IOLBF, 0)

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

private func makeSpotifyController(auth: SpotifyAuth, http: any HTTPClient) throws -> WebApiSpotifyController {
    let config = try SpotifyConfigLoader.load(path: "config/spotify.local.yaml")
    return WebApiSpotifyController(auth: auth, http: http, preferredDeviceName: config.deviceName)
}

func runTtsDemo() async {
    print("ケイラボAIラジオ Mac版 — TTS デモ（VOICEVOX）")
    do {
        let config = try TtsConfigLoader.load(path: "config/tts.yaml")
        let tts = VoicevoxTTS(endpoint: config.endpoint, http: URLSessionHTTPClient())
        let wav = try await tts.synthesize(text: "こんにちは。ケイラボAIラジオのテストなのだ。", speakerId: 3)
        print("合成成功: \(wav.count) bytes")
        try await AVAudioPlayerBackend(volume: Float(config.playbackVolume)).play(wav)
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
        let controller = try makeSpotifyController(auth: auth, http: http)

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
        let research = try ResearchConfigLoader.load(path: "config/research.yaml")
        let ttsConfig = try TtsConfigLoader.load(path: "config/tts.yaml")
        let http = URLSessionHTTPClient()
        let auth = try makeSpotifyAuth()
        let sequencer = ThemeSequencer(
            tts: VoicevoxTTS(endpoint: ttsConfig.endpoint, http: http),
            audio: AVAudioPlayerBackend(volume: Float(ttsConfig.playbackVolume)),
            spotify: try makeSpotifyController(auth: auth, http: http),
            clock: SystemClock()
        )
        let speakerId = 3  // ずんだもん

        // ニュースセグメントは実データ（Google News RSS + 気象庁）で原稿を生成（fail-tolerant）。
        let newsWeather = NewsWeatherProvider(
            news: NewsRssSource(url: research.newsRssUrl, maxItems: research.newsMaxItems, http: http),
            weather: JmaWeatherSource(areaCode: research.weatherAreaCode, areaName: research.weatherAreaName, http: http),
            template: research.announcementTemplate
        )
        print("ニュース・天気を取得中…")
        let newsAnnouncement = await newsWeather.announcement()
        print("ニュース原稿: \(newsAnnouncement.prefix(80))…")

        let segments: [(String, ThemeConfig, String)] = [
            ("オープニング", themes.opening.theme, themes.opening.announcement),
            ("ニュースと天気", themes.news.theme, newsAnnouncement),
            ("エンディング", themes.ending.theme, themes.ending.announcement),
        ]
        for (name, theme, announcement) in segments {
            print("=== \(name) ===")
            try await sequencer.run(theme: theme, announcement: announcement, speakerId: speakerId)
            print("\(name) 完了")
        }
        print("デモ完了")
    } catch let error as RadioError {
        print("エラー[\(error.code)]: \(error.message)")
    } catch {
        print("エラー: \(error)")
    }
}

func runNewsDemo() async {
    print("ケイラボAIラジオ Mac版 — ニュース・天気 取得デモ（音声なし）")
    do {
        let research = try ResearchConfigLoader.load(path: "config/research.yaml")
        let http = URLSessionHTTPClient()
        let newsWeather = NewsWeatherProvider(
            news: NewsRssSource(url: research.newsRssUrl, maxItems: research.newsMaxItems, http: http),
            weather: JmaWeatherSource(areaCode: research.weatherAreaCode, areaName: research.weatherAreaName, http: http),
            template: research.announcementTemplate
        )
        let announcement = await newsWeather.announcement()
        print("--- ニュース原稿 ---")
        print(announcement)
    } catch let error as RadioError {
        print("エラー[\(error.code)]: \(error.message)")
    } catch {
        print("エラー: \(error)")
    }
}

func runCornerDemo() async {
    print("ケイラボAIラジオ Mac版 — 会話コーナー デモ（LLM 台本 → DJ 二人 → 一曲）")
    do {
        let llmConfig = try LlmConfigLoader.load(path: "config/llm.yaml", localPath: "config/llm.local.yaml")
        let djs = try DjsConfigLoader.load(path: "config/djs.yaml")
        let corners = try CornersConfigLoader.load(path: "config/corners.yaml")
        guard let corner = corners.first else {
            throw ConfigError.missingField("corners")
        }
        let ttsConfig = try TtsConfigLoader.load(path: "config/tts.yaml")
        let spotifyConfig = try SpotifyConfigLoader.load(path: "config/spotify.local.yaml")
        let http = URLSessionHTTPClient()
        let auth = try makeSpotifyAuth()
        let engine = CornerEngine(
            llm: GeminiLLMBackend(config: llmConfig, http: http),
            tts: VoicevoxTTS(endpoint: ttsConfig.endpoint, http: http),
            audio: AVAudioPlayerBackend(volume: Float(ttsConfig.playbackVolume)),
            searcher: SpotifyWebSearcher(auth: auth, market: spotifyConfig.market, http: http),
            spotify: try makeSpotifyController(auth: auth, http: http),
            clock: SystemClock(),
            temperature: llmConfig.temperature,
            onEvent: { event in
                switch event {
                case .songPicked(let track):
                    let label = track.title.isEmpty ? track.uri : "\(track.artist) / \(track.title)"
                    print("締めの曲（プレフライト済み）: \(label)")
                case .scriptReady(let lineCount, let totalCharacters):
                    print("台本生成完了: \(lineCount) 行 / \(totalCharacters) 文字")
                case .line(let line):
                    print("  \(line.djId): \(line.text)")
                case .songStarted(let track):
                    let label = track.title.isEmpty ? track.uri : "\(track.artist) / \(track.title)"
                    print("♪ 再生中: \(label)")
                }
            }
        )
        print("コーナー「\(corner.title)」テーマ: \(corner.theme)")
        try await engine.run(corner: corner, djs: djs)
        print("コーナー完了")
    } catch let error as RadioError {
        print("エラー[\(error.code)]: \(error.message)")
    } catch {
        print("エラー: \(error)")
    }
}

func runBroadcastDemo() async {
    print("ケイラボAIラジオ Mac版 — 放送デモ（番組 1 周、Ctrl-C で停止）")
    do {
        let program = try ProgramConfigLoader.load(path: "config/program.yaml")
        let themes = try ThemeConfigLoader.load(path: "config/themes.yaml")
        let research = try ResearchConfigLoader.load(path: "config/research.yaml")
        let llmConfig = try LlmConfigLoader.load(path: "config/llm.yaml", localPath: "config/llm.local.yaml")
        let djs = try DjsConfigLoader.load(path: "config/djs.yaml")
        let corners = try CornersConfigLoader.load(path: "config/corners.yaml")
        let ttsConfig = try TtsConfigLoader.load(path: "config/tts.yaml")
        let spotifyConfig = try SpotifyConfigLoader.load(path: "config/spotify.local.yaml")

        let http = URLSessionHTTPClient()
        let auth = try makeSpotifyAuth()
        let tts = VoicevoxTTS(endpoint: ttsConfig.endpoint, http: http)
        let audio = AVAudioPlayerBackend(volume: Float(ttsConfig.playbackVolume))
        let spotify = try makeSpotifyController(auth: auth, http: http)
        let clock = SystemClock()

        let cornerEngine = CornerEngine(
            llm: GeminiLLMBackend(config: llmConfig, http: http),
            tts: tts,
            audio: audio,
            searcher: SpotifyWebSearcher(auth: auth, market: spotifyConfig.market, http: http),
            spotify: spotify,
            clock: clock,
            temperature: llmConfig.temperature,
            onEvent: { event in
                switch event {
                case .songPicked(let track):
                    print("  締めの曲: \(track.title.isEmpty ? track.uri : "\(track.artist) / \(track.title)")")
                case .scriptReady(let lineCount, let totalCharacters):
                    print("  台本: \(lineCount) 行 / \(totalCharacters) 文字")
                case .line(let line):
                    print("    \(line.djId): \(line.text)")
                case .songStarted:
                    print("  ♪ 再生中…")
                }
            }
        )
        let newsProvider = NewsWeatherProvider(
            news: NewsRssSource(url: research.newsRssUrl, maxItems: research.newsMaxItems, http: http),
            weather: JmaWeatherSource(areaCode: research.weatherAreaCode, areaName: research.weatherAreaName, http: http),
            template: research.announcementTemplate
        )
        let engine = BroadcastEngine(
            themes: BroadcastThemes(
                opening: ThemedAnnouncement(theme: themes.opening.theme, announcement: themes.opening.announcement),
                news: themes.news.theme,
                ending: ThemedAnnouncement(theme: themes.ending.theme, announcement: themes.ending.announcement),
                greetings: themes.greetings
            ),
            themeSequencer: ThemeSequencer(tts: tts, audio: audio, spotify: spotify, clock: clock),
            cornerRunner: cornerEngine,
            newsProvider: newsProvider,
            spotify: spotify,
            clock: clock,
            onEvent: { event in
                switch event {
                case .segmentStarted(let index, let kind):
                    print("=== [\(index + 1)] \(kind.rawValue) ===")
                case .segmentFinished(let index, let kind):
                    print("=== [\(index + 1)] \(kind.rawValue) 完了 ===")
                case .segmentFailed(let index, let kind, let code, let detail):
                    let error = BroadcastError.segmentFailed(code)
                    print("=== [\(index + 1)] \(kind.rawValue) エラー[\(error.code)]: \(error.message) ===")
                    print("    詳細: \(detail)")
                case .broadcastFinished:
                    print("=== 放送終了 ===")
                }
            }
        )
        print("番組「\(program.title)」を開始します（全 \(program.segments.count) セグメント）")
        try await engine.run(program: program, corners: corners, djs: djs)
    } catch is CancellationError {
        print("停止しました（完全静寂）")
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
case "news": await runNewsDemo()
case "corner": await runCornerDemo()
case "broadcast":
    // 放送全体を 1 つの Task で回し、Ctrl-C（SIGINT）で Task.cancel()（CLAUDE.md §3-1）。
    let broadcastTask = Task { await runBroadcastDemo() }
    signal(SIGINT, SIG_IGN)
    // 注意: ハンドラはトップレベル変数（MainActor 分離）に触るため、必ず main キューで動かす。
    // .global() だと Swift 6 の実行時分離チェック（dispatch_assert_queue）で SIGTRAP クラッシュする。
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        print("\n停止します…（後始末中）")
        broadcastTask.cancel()
    }
    sigint.resume()
    print("(Ctrl-C で停止できます)")
    await broadcastTask.value
default: await runTtsDemo()
}
