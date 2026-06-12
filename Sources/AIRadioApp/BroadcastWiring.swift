import Foundation
import AIRadioCore
import AIRadioInfra

let spotifyScopes = ["user-read-playback-state", "user-modify-playback-state"]

func makeSpotifyAuth() throws -> SpotifyAuth {
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

func makeSpotifyController(auth: SpotifyAuth, http: any HTTPClient) throws -> WebApiSpotifyController {
    let config = try SpotifyConfigLoader.load(path: "config/spotify.local.yaml")
    return WebApiSpotifyController(auth: auth, http: http, preferredDeviceName: config.deviceName)
}

/// 放送 1 本ぶんの配線済み一式（broadcast デモとメニューバー UI が共用）。
struct BroadcastStack {
    let engine: BroadcastEngine
    let program: Program
    let corners: [CornerTemplate]
    let djs: [DjProfile]

    func run() async throws {
        try await engine.run(program: program, corners: corners, djs: djs)
    }
}

/// config/ 一式を読み込み、BroadcastEngine を配線する（fail-fast: 設定不正はここで throw）。
/// 開始のたびに呼ぶことで YAML の編集が次の放送から反映される。
func makeBroadcastStack(
    onBroadcastEvent: (@Sendable (BroadcastEvent) -> Void)? = nil,
    onCornerEvent: (@Sendable (CornerEvent) -> Void)? = nil
) throws -> BroadcastStack {
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
    let tts = VoicevoxTTS(endpoint: ttsConfig.endpoint, http: http, speedScale: ttsConfig.speedScale)
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
        onEvent: onCornerEvent
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
        onEvent: onBroadcastEvent
    )
    return BroadcastStack(engine: engine, program: program, corners: corners, djs: djs)
}

/// コーナー進行のコンソール出力（デモ・常駐どちらでも進行ログとして使う）。
@Sendable func printCornerEvent(_ event: CornerEvent) {
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

/// 放送進行のコンソール出力。
@Sendable func printBroadcastEvent(_ event: BroadcastEvent) {
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
