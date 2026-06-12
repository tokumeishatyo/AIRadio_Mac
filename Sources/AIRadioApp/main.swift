import Foundation
import AIRadioCore
import AIRadioInfra

// エントリポイント。AIRADIO_DEMO なし（既定）= メニューバー常駐アプリ（S9）。
// CLI デモは AIRADIO_DEMO で切替:
//   AIRADIO_DEMO=tts           VOICEVOX 合成 + 再生
//   AIRADIO_DEMO=spotify-auth  Spotify ログイン（PKCE、ブラウザ、初回のみ）
//   AIRADIO_DEMO=spotify       Spotify 検索 + Web API 再生
//   AIRADIO_DEMO=theme         統一テーマエンジン（OP / ニュース / ED）
//   AIRADIO_DEMO=corner        会話コーナー（LLM 台本 → DJ 二人の会話 → 一曲）
//   AIRADIO_DEMO=broadcast     番組 1 周（OP → トーク → ニュース天気 → ED、Ctrl-C で停止）
//   AIRADIO_DEMO=trackwatch    診断: フル再生の終端検知を全ログで観測（AIRADIO_TRACK_QUERY で曲指定）
// 診断: AIRADIO_SPOTIFY_LOG=1 で放送中の全 Spotify 呼び出しを経過秒付きでログ出力。

// リダイレクト時も進行ログが即時見えるよう、stdout を行バッファリングにする。
setvbuf(stdout, nil, _IOLBF, 0)

func runTtsDemo() async {
    print("ケイラボAIラジオ Mac版 — TTS デモ（VOICEVOX）")
    do {
        let config = try TtsConfigLoader.load(path: "config/tts.yaml")
        let tts = VoicevoxTTS(endpoint: config.endpoint, http: URLSessionHTTPClient(), speedScale: config.speedScale)
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
            tts: VoicevoxTTS(endpoint: ttsConfig.endpoint, http: http, speedScale: ttsConfig.speedScale),
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
    print("ケイラボAIラジオ Mac版 — ニュース原稿デモ（LLM アナウンサー原稿、音声なし）")
    do {
        let research = try ResearchConfigLoader.load(path: "config/research.yaml")
        let http = URLSessionHTTPClient()
        let news = NewsRssSource(url: research.newsRssUrl, maxItems: research.newsMaxItems, http: http)
        let weather = JmaWeatherSource(
            areaCode: research.weatherAreaCode, areaName: research.weatherAreaName, http: http)

        let provider: any AnnouncementProviding
        if let llmConfig = try? LlmConfigLoader.load(path: "config/llm.yaml", localPath: "config/llm.local.yaml") {
            let djs = (try? DjsConfigLoader.load(path: "config/djs.yaml")) ?? []
            provider = LlmNewsScriptProvider(
                news: news,
                weather: weather,
                llm: GeminiLLMBackend(config: llmConfig, http: http),
                persona: djs.first { $0.id == "ryusei" }?.persona ?? "",
                style: research.llmScript,
                fallbackTemplate: research.announcementTemplate
            )
        } else {
            print("（LLM キー未設定のため定型テンプレ原稿で表示します）")
            provider = NewsWeatherProvider(
                news: news, weather: weather, template: research.announcementTemplate)
        }
        let announcement = await provider.announcement()
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
            tts: VoicevoxTTS(endpoint: ttsConfig.endpoint, http: http, speedScale: ttsConfig.speedScale),
            audio: AVAudioPlayerBackend(volume: Float(ttsConfig.playbackVolume)),
            searcher: SpotifyWebSearcher(auth: auth, market: spotifyConfig.market, http: http),
            spotify: try makeSpotifyController(auth: auth, http: http),
            clock: SystemClock(),
            temperature: llmConfig.temperature,
            onEvent: { event in
                switch event {
                case .themeSelected(let theme):
                    print("テーマ: \(theme)")
                case .letterReady(let radioName):
                    print("お便り: ラジオネーム \(radioName)")
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
                case .songFinished(let reason):
                    print("♪ 曲終了（検知: \(reason.rawValue)）")
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

/// 診断: SpotifyController の全呼び出しを経過秒付きでログする（trackwatch 用）。
struct LoggingSpotifyController: SpotifyController {
    let inner: any SpotifyController
    let start: Date

    private func log(_ message: String) {
        print(String(format: "[%7.2fs] %@", Date().timeIntervalSince(start), message))
    }

    func play(uri: String) async throws {
        log("play(\(uri))")
        try await inner.play(uri: uri)
        log("play 完了")
    }
    func pause() async throws {
        log("pause()")
        try await inner.pause()
    }
    func setVolume(_ percent: Int) async throws {
        log("setVolume(\(percent))")
        try await inner.setVolume(percent)
    }
    func seek(toSeconds seconds: Int) async throws {
        log("seek(\(seconds))")
        try await inner.seek(toSeconds: seconds)
    }
    func playerState() async throws -> PlayerState {
        let state = try await inner.playerState()
        log("playerState → \(state.state.rawValue) uri=\(state.trackUri ?? "nil")"
            + " pos=\(String(format: "%.1f", state.positionSeconds))"
            + " dur=\(String(format: "%.1f", state.durationSeconds))")
        return state
    }
    func currentTrackDurationSeconds() async throws -> Double {
        let duration = try await inner.currentTrackDurationSeconds()
        log("duration → \(String(format: "%.1f", duration))")
        return duration
    }
}

/// 診断デモ: OP → 冒頭曲の遷移を再現し、waitForTrackToFinish の挙動を全ログで観測する。
/// 「曲が途中で終わる」報告（S12 ライブ確認）の原因切り分け用。
func runTrackWatchDemo() async {
    print("ケイラボAIラジオ Mac版 — trackwatch 診断（OP 遷移再現 + フル再生監視）")
    do {
        let themes = try ThemeConfigLoader.load(path: "config/themes.yaml")
        let config = try SpotifyConfigLoader.load(path: "config/spotify.local.yaml")
        let auth = try makeSpotifyAuth()
        let http = URLSessionHTTPClient()
        let searcher = SpotifyWebSearcher(auth: auth, market: config.market, http: http)
        let inner = try makeSpotifyController(auth: auth, http: http)
        let clock = SystemClock()
        let spotify = LoggingSpotifyController(inner: inner, start: Date())

        // 0. 監視対象の長尺曲（約 6 分）を検索で確定
        let query = ProcessInfo.processInfo.environment["AIRADIO_TRACK_QUERY"] ?? "Bohemian Rhapsody Queen"
        guard let target = try await searcher.search(query: query, limit: 3).first(where: { $0.isPlayable }) else {
            print("対象曲が見つかりません: \(query)")
            return
        }
        print("対象曲: \(target.artist) / \(target.title) \(target.uri)")

        // 1. OP の終わり方を再現: BGM を頭から数秒 → 終端 10 秒前へシーク → 自然終了 → pause
        print("--- OP 遷移の再現（BGM 終端で停止した状態を作る）---")
        try await spotify.play(uri: themes.opening.theme.trackUri)
        try await clock.sleep(seconds: 3)
        let bgmDuration = try await spotify.currentTrackDurationSeconds()
        if bgmDuration > 10 {
            try await spotify.seek(toSeconds: Int(bgmDuration.rounded()) - 10)
        }
        try await clock.sleep(seconds: 12)
        try await spotify.pause()

        // 2. 冒頭曲: play 直後から waitForTrackToFinish を全ログで観測
        print("--- 冒頭曲のフル再生監視（曲長 \(target.uri)）---")
        try await spotify.play(uri: target.uri)
        try await spotify.setVolume(100)
        let waitStart = Date()
        try await spotify.waitForTrackToFinish(of: target.uri, clock: clock)
        let waited = Date().timeIntervalSince(waitStart)
        print(String(format: "waitForTrackToFinish が %.1f 秒で戻りました", waited))
        let finalState = try await spotify.playerState()
        print("最終状態: \(finalState.state.rawValue) pos=\(String(format: "%.1f", finalState.positionSeconds))")
        if finalState.state == .playing, finalState.trackUri == target.uri {
            print("⚠️ 曲がまだ再生中に戻っています（途中切りを再現）")
        }
        try await spotify.pause()
        print("診断完了")
    } catch let error as RadioError {
        print("エラー[\(error.code)]: \(error.message)")
    } catch {
        print("エラー: \(error)")
    }
}

func runBroadcastDemo() async {
    print("ケイラボAIラジオ Mac版 — 放送デモ（番組 1 周、Ctrl-C で停止）")
    do {
        let stack = try makeBroadcastStack(
            onBroadcastEvent: printBroadcastEvent,
            onCornerEvent: printCornerEvent
        )
        print("番組「\(stack.program.title)」を開始します（全 \(stack.program.segments.count) セグメント）")
        try await stack.run()
    } catch is CancellationError {
        print("停止しました（完全静寂）")
    } catch let error as RadioError {
        print("エラー[\(error.code)]: \(error.message)")
    } catch {
        print("エラー: \(error)")
    }
}

switch ProcessInfo.processInfo.environment["AIRADIO_DEMO"] {
case nil, .some(""):
    // 既定: メニューバー常駐アプリ（S9）。CLI デモは AIRADIO_DEMO 指定時のみ。
    runMenuBarApp()
case "tts": await runTtsDemo()
case "spotify-auth": await runSpotifyAuthDemo()
case "spotify": await runSpotifyDemo()
case "theme": await runThemeDemo()
case "news": await runNewsDemo()
case "corner": await runCornerDemo()
case "trackwatch": await runTrackWatchDemo()
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
case .some(let unknown):
    print("不明な AIRADIO_DEMO: \(unknown)（tts / news / spotify-auth / spotify / theme / corner / broadcast）")
    exit(1)
}
