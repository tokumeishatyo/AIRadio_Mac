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

/// メニュー「番組の長さ」の UserDefaults キー（値は ProgramLength.rawValue: "10" / "endless" 等）。
let programLengthDefaultsKey = "programLength"

/// 番組の長さ: UserDefaults の選択値（メニューで変更・保持）が優先、なければ program.yaml の既定値。
func selectedProgramLength(defaultLength: ProgramLength) -> ProgramLength {
    if let raw = UserDefaults.standard.string(forKey: programLengthDefaultsKey),
       let length = ProgramLength(rawValue: raw) {
        return length
    }
    return defaultLength
}

/// 番組の長さの表示ラベル。
func programLengthLabel(_ length: ProgramLength) -> String {
    switch length {
    case .corners(let count): return "トーク \(count) 本"
    case .endless: return "エンドレス"
    }
}

/// 放送 1 本ぶんの配線済み一式（broadcast デモとメニューバー UI が共用）。
struct BroadcastStack {
    let engine: BroadcastEngine
    let plan: ProgramPlan
    let corners: [CornerTemplate]
    let djs: [DjProfile]
    /// 放送中の操作（「ED で終了」）。
    let control: BroadcastControl

    func run() async throws {
        try await engine.run(plan: plan, corners: corners, djs: djs, control: control)
    }
}

/// config/ 一式を読み込み、BroadcastEngine を配線する（fail-fast: 設定不正はここで throw）。
/// 開始のたびに呼ぶことで YAML の編集が次の放送から反映される。
func makeBroadcastStack(
    onBroadcastEvent: (@Sendable (BroadcastEvent) -> Void)? = nil,
    onCornerEvent: (@Sendable (CornerEvent) -> Void)? = nil
) throws -> BroadcastStack {
    let blueprint = try ProgramConfigLoader.load(path: "config/program.yaml")
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
    // AIRADIO_SPOTIFY_LOG=1 で全 Spotify 呼び出しを経過秒付きでログ（途中切り等の診断用）。
    var spotify: any SpotifyController = try makeSpotifyController(auth: auth, http: http)
    if ProcessInfo.processInfo.environment["AIRADIO_SPOTIFY_LOG"] == "1" {
        spotify = LoggingSpotifyController(inner: spotify, start: Date())
    }
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
    // ニュース原稿は LLM アナウンサー原稿（S11）。読み手（news の dj_id、なければ anchor）のペルソナを使う。
    let newsDjId = blueprint.newsDjId ?? blueprint.anchorDjId
    let newsPersona = djs.first { $0.id == newsDjId }?.persona ?? ""
    let newsProvider = LlmNewsScriptProvider(
        news: NewsRssSource(url: research.newsRssUrl, maxItems: research.newsMaxItems, http: http),
        weather: JmaWeatherSource(areaCode: research.weatherAreaCode, areaName: research.weatherAreaName, http: http),
        llm: GeminiLLMBackend(config: llmConfig, http: http),
        persona: newsPersona,
        style: research.llmScript,
        fallbackTemplate: research.announcementTemplate
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
        songPicker: SongPicker(
            llm: GeminiLLMBackend(config: llmConfig, http: http),
            searcher: SpotifyWebSearcher(auth: auth, market: spotifyConfig.market, http: http),
            temperature: llmConfig.temperature
        ),
        spotify: spotify,
        clock: clock,
        onEvent: onBroadcastEvent
    )
    let plan = ProgramPlan(
        blueprint: blueprint,
        length: selectedProgramLength(defaultLength: blueprint.defaultLength)
    )
    return BroadcastStack(engine: engine, plan: plan, corners: corners, djs: djs, control: BroadcastControl())
}

/// コーナー進行のコンソール出力（デモ・常駐どちらでも進行ログとして使う）。
@Sendable func printCornerEvent(_ event: CornerEvent) {
    switch event {
    case .themeSelected(let theme):
        print("  テーマ: \(theme)")
    case .letterReady(let radioName):
        print("  お便り: ラジオネーム \(radioName)")
    case .songPicked(let track):
        print("  締めの曲: \(track.title.isEmpty ? track.uri : "\(track.artist) / \(track.title)")")
    case .scriptReady(let lineCount, let totalCharacters):
        print("  台本: \(lineCount) 行 / \(totalCharacters) 文字")
    case .line(let line):
        print("    \(line.djId): \(line.text)")
    case .songStarted:
        print("  ♪ 再生中…")
    case .songFinished(let reason):
        print("  ♪ 曲終了（検知: \(reason.rawValue)）")
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
    case .songStarted(_, let track):
        print("  ♪ \(track.title.isEmpty ? track.uri : "\(track.artist) / \(track.title)")")
    case .songFinished(_, let reason):
        print("  ♪ 曲終了（検知: \(reason.rawValue)）")
    case .endingRequested:
        print("=== ED で終了を受け付けました（残りのコーナーを飛ばして ED へ）===")
    case .broadcastFinished:
        print("=== 放送終了 ===")
    }
}
