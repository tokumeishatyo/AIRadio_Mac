# 引き継ぎ（再開ガイド）— ケイラボAIラジオ Mac版

> セッションをまたいで再開するための現在地まとめ。最終更新: 2026-06-07（S5完了時点）。
> 横断ルールは `../CLAUDE.md`、要件/設計/仕様は Confluence（下記）を参照。

## 1. 何を作っているか
AI DJ が気ままに喋り Spotify の曲をかける、メニューバー常駐型の自律 AI ラジオ「ケイラボAIラジオ」の **Mac 版**。
Windows 版（`../AIRadio-main/`、C#/.NET、**読み取り専用の参考**）の精神を継承しつつ Swift で簡素化。

## 2. 場所・リンク
- リポジトリ root: `/Users/kawasaki/Develop/AIRadio/AIRadioMac`（**ここが git root**）
- GitHub: `git@github.com:tokumeishatyo/AIRadio_Mac.git`（SSH、ブランチ `main`）。push は認証済みで自動完結可。
- 隣接: `../方針.md`（出発メモ、git 除外）、`../AIRadio-main/`（Windows 参考、編集禁止）
- Confluence（site `aaic.atlassian.net` / space `AIRadio` id=28835843 / Home=28835940）:
  - 要件定義 = **37519362** / 設計 = **37617666** / 仕様ハブ = **37519389** / CLAUDE.md ミラー = **37486597**
  - 仕様ミラー: S0=37519413, S1=37519437, S2=37519471, S3=37486636, S4=37519505, S5=37617721

## 3. 進捗（S0〜S5 完了、次は S6）
| スライス | 内容 | 状態 |
|---|---|---|
| S0 | SwiftPM スケルトン + Core protocol + テスト土台 | ✅ |
| S1 | VOICEVOX TTS + 音声再生 | ✅（聴覚確認済み） |
| S2 | Spotify 検索基盤（AppleScript 再生は S4 で置換） | ✅ |
| S3 | 統一テーマ/BGM エンジン（OP/ニュース/ED 共有演出） | ✅（ライブ確認済み） |
| S4 | Spotify Web API 再生 + OAuth(PKCE) | ✅（ライブ確認済み） |
| S5 | ニュース・天気の実データ（Google News RSS + 気象庁） | ✅（実データ確認済み） |
| **S6** | **Gemini 台本生成（LLM 統合）** | ⏭ 次 |

`swift test` = **82 件グリーン**。最新コミット `7362b65`（S5）。

## 4. ビルド・テスト・実行
```bash
cd ~/Develop/AIRadio/AIRadioMac
swift build
swift test                       # 82 件
AIRADIO_DEMO=tts         swift run AIRadioApp   # 既定: VOICEVOX 合成+再生
AIRADIO_DEMO=news        swift run AIRadioApp   # ニュース原稿を表示（音声なし、ネットだけ）
AIRADIO_DEMO=spotify-auth swift run AIRadioApp  # Spotify ログイン（PKCE、初回のみ。済）
AIRADIO_DEMO=spotify     swift run AIRadioApp   # 検索 + Web API 再生
AIRADIO_DEMO=theme       swift run AIRadioApp   # OP→ニュース(実データ)→ED の統一演出
```
メニューバー UI と放送エンジンは未実装（S7 以降）。今は `main.swift` のデモ切替で動作確認している。

## 5. 環境・前提
- Swift 6.2 / swift-tools 6.0 / macOS 13。Xcode ライセンス同意済み。
- **VOICEVOX** をローカル起動（HTTP `127.0.0.1:50021`）しておくこと。
- **Spotify デスクトップアプリ起動 + Premium**。Web API 再生にはアクティブデバイスが必要。
- **Spotify OAuth は認証済み**（refresh トークンが Keychain `AIRadio.Spotify/refresh_token` に保存済み）。
  redirect_uri = `http://127.0.0.1:5543/callback`（Spotify Dashboard 登録済み、Windows 版と共用）。
  ※ Keychain アクセス時のプロンプトは、未署名 `swift run` だと再ビルドごとに出ることがある（署名 .app 化で解消）。
- **S6 で Gemini API キーが必要** → `config/llm.local.yaml`（gitignore 対象）に置く予定。
- 依存パッケージは **Yams 1 つのみ**。

## 6. アーキテクチャ（3 層、依存は外→内）
- `Sources/AIRadioCore/` — protocol + ドメイン + 純粋ロジック（外部依存ゼロ、テストの中心）
  - protocol: `LLMBackend` / `TTSBackend` / `AudioPlayer` / `TrackSearcher` / `SpotifyController` / `ResearchSource` / `Clock`
  - 型: `ThemeConfig` / `ThemeSequencer`(+`ThemeSequencing`) / `TemplateExpander` / `SpotifyURI` / `PlayerState` 等
  - エラー: `RadioError` + `SpotifyError`/`ConfigError`/`TtsError`/`AudioError`/`ResearchError`（コード台帳 `docs/specs/error-codes.md`）
- `Sources/AIRadioInfra/` — 外部実装
  - TTS: `VoicevoxTTS` / 音声: `AVAudioPlayerBackend` / HTTP: `HTTPClient`+`URLSessionHTTPClient`
  - Spotify: `SpotifyAuth`(actor,PKCE) + `LoopbackServer` + `PKCE` + `KeychainTokenStore` + `WebApiSpotifyController` + `SpotifyWebSearcher`（`AppleScript*` は代替として残置）
  - リサーチ: `NewsRssSource` / `JmaWeatherSource` / `NewsWeatherProvider`
  - 設定ローダ: `TtsConfig` / `SpotifyConfig` / `ThemeConfigLoader` / `ResearchConfig`
- `Sources/AIRadioApp/` — `main.swift`（デモ配線。将来メニューバー UI）
- `Sources/AIRadioTestSupport/` — fake 一式（Echo/InMemory/Spy/Fake 群）
- `Tests/AIRadioCoreTests`, `Tests/AIRadioInfraTests`（共有ヘルパは `Tests/AIRadioInfraTests/Helpers/`）

## 7. 設定ファイル（`config/`）
- `tts.yaml`（VOICEVOX endpoint/credit）、`themes.yaml`（OP/news/ending の演出 + 文言）、`research.yaml`（RSS URL / area_code=130000 東京 / テンプレ）
- `spotify.local.yaml`（**gitignore**、client_id/redirect_uri/market。secret 不要）、`spotify.local.yaml.sample`（コミット）
- 命名: kebab-case ファイル / snake_case キー / 機密は `*.local.yaml`

## 8. 重要な決定・ハマりどころ（再発防止）
- **Spotify 再生は Web API（PKCE OAuth）にした**（当初の AppleScript ハイブリッドから変更）。理由: AppleScript の `play track` を一時停止状態から呼ぶと前曲が一瞬鳴る（ミュートで隠すと無音区間が出る）。Web API の `play`（uris 指定）はアトミックで両方を回避（Windows 版と同じ）。検索もユーザートークンに統一し client_secret 廃止。
- **pause はベストエフォート**（403 握り潰し）: 曲が自然終了した直後の pause は Spotify が 403 を返すが結果は同じ無音。後始末で放送を止めない（CLAUDE.md §3-1）。
- **AppleScript は単一行で書く**: 複数行を `osascript -e` に渡すと構文エラー(-2741)。
- **完全静寂**: テーマ/放送は最後に必ず `pause`（正常・例外・キャンセルいずれも）。
- **outro 演出**: 曲長 - `outro_seconds` の位置へシークし、曲の自然な終わりで停止（Windows OpeningSequencer 踏襲）。
- ニュースが毎回同じに見えるのは**キャッシュではなく**（RSS は `no-store`）、トップ見出しが短時間で変わらないだけ。時間が経てば変わる。

## 9. 仕様駆動ワークフロー（毎スライス）
1. `docs/specs/<feature>.md` を書く → 2. git commit → 3. Confluence『Mac版 仕様』にミラー（チェックリスト付き）→ 4. 実装 + `swift test` グリーン → 5. git commit/push → 6. チェック更新。
（コミット/プッシュはユーザー指示時。聴覚・視覚・ライブ確認はユーザーに依頼し、結果を反映。）

## 10. 次にやる S6（Gemini 台本生成）の見取り図
- `GeminiLLMBackend`（Infra, `LLMBackend` 実装）: `generativelanguage.googleapis.com` に HTTP。`config/llm.yaml`（active engine/model、非機密）+ `config/llm.local.yaml`（API キー、gitignore）。
- **モデル ID をまず API で実在確認**（「Gemini 3.1 Flash Lite」「Gemma 4 26B」の正確な識別子）。無料枠。
- 決定論的な定型文を LLM 生成に差し替え（ニュースへのコメント、DJ の今日の気分、お便り等）。プロンプト構築は `PromptBuilder` 的な Core ロジック。
- 失敗時フォールバック（LLM 不調でも放送継続）。Echo 実装でテスト。
