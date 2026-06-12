# 引き継ぎ（再開ガイド）— ケイラボAIラジオ Mac版

> セッションをまたいで再開するための現在地まとめ。最終更新: 2026-06-12（S11 完了時点）。
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

## 3. 進捗（S0〜S11 完了、次は S12）
| スライス | 内容 | 状態 |
|---|---|---|
| S0 | SwiftPM スケルトン + Core protocol + テスト土台 | ✅ |
| S1 | VOICEVOX TTS + 音声再生 | ✅（聴覚確認済み） |
| S2 | Spotify 検索基盤（AppleScript 再生は S4 で置換） | ✅ |
| S3 | 統一テーマ/BGM エンジン（OP/ニュース/ED 共有演出） | ✅（ライブ確認済み） |
| S4 | Spotify Web API 再生 + OAuth(PKCE) | ✅（ライブ確認済み） |
| S5 | ニュース・天気の実データ（Google News RSS + 気象庁） | ✅（実データ確認済み） |
| S6 | Gemini 台本生成 + DJ 二人の会話コーナー | ✅（ライブ確認済み 2026-06-12） |
| S7 | 番組進行エンジン（BroadcastEngine + program.yaml） | ✅（通し + Ctrl-C 静寂 確認済み 2026-06-12） |
| S8 | 時刻・日付入りアナウンス + ニュース DJ=青山龍星 + 音量バランス + 話速 | ✅（実時刻読み上げ確認済み 2026-06-12） |
| S9 | メニューバー常駐 UI（開始/停止/終了、既定起動） | ✅（ライブ確認済み 2026-06-12） |
| S10 | 切れ目ない放送（冒頭曲セグメント + コーナー先行準備） | ✅（ライブ確認済み 2026-06-12） |
| S11 | ニュースの LLM 会話化（アナウンサー原稿） | ✅（原稿はデモで確認済み。**ダッキング直後の即発話のみ次回放送時に聴取確認**） |
| **S12** | **候補: 番組の連続ループ・13 項目拡張 / 署名 .app バンドル化（ユーザーと相談して決める）** | ⏭ 次 |

`swift test` = **179 件グリーン**。仕様 = `docs/specs/s11-llm-news.md` / Confluence S11=39223320（S10=39223298, S9=39092225, S8=38993921, S7=38895618, S6=38731777）。
- ニュース原稿は LLM 生成（`NewsScriptGenerator` + `LlmNewsScriptProvider`）: 固定の時報イントロ +
  本文（語り + コメント、約 2 分）+ 固定アウトロ。LLM 失敗時は S5 の定型テンプレに倒す。
  スタイル・長さは research.yaml の `llm_script:`、ペルソナは news セグメント dj_id（龍星）。
- ニュース原稿も先行準備（放送開始時に生成）。テーマ発話は**文単位チャンクのパイプライン合成**
  （長文を一括合成するとダッキング後に 10 秒超の合成待ちが出るため、S11 fix）。
- 番組構成は OP → **song（冒頭曲）** → talk → news → ED の 5 セグメント。
- **切れ目ない放送**: 放送開始時に全 song 選曲・全 talk 準備（LLM + 全行 TTS 事前合成）を並行起動。
  OP は 1 曲目確定後に開始し `{first_song}` で曲振り。曲の終端は `waitForTrackToFinish`
  （URI 切替確認 → 残り待ち → 停止/遷移/終端到達/位置停滞のいずれかで即抜け）。
- **既定起動 = メニューバー常駐**: `swift run AIRadioApp`（AIRADIO_DEMO なし）→ 📻 常駐（.accessory）。
  メニュー「放送を開始/停止/終了」。停止 = `BroadcastSession.stop()`（Task.cancel → S7 機構で完全静寂）。
  終了時も `applicationShouldTerminate` で stop してから閉じる。設定 YAML は開始のたびに読み直す。
- 時刻アナウンス: `TimePhrases`（{greeting}/{month}/{day}/{ampm}/{hour}/{hour12}/{minute}）を発話直前に展開。
  挨拶境界は Windows 踏襲（朝5-11/昼12-16/夜17-4）、文字列は themes.yaml の `greetings:`。
- ニュースは program.yaml の `dj_id: ryusei`（青山龍星=speaker 13）。テーマ系セグメントは dj_id で個別指定可。
- **音量・話速は config で調整**: 音楽=themes/corners の `volume`（現在 100）、声=tts.yaml の
  `playback_volume`（0〜1、現在 0.8）と `speed_scale`（話速、1.0=標準、現在 1.15）。
  いずれも YAML 編集のみ・再ビルド不要（ユーザーが好みに調整中）。
- 番組進行: `config/program.yaml` のセグメント列（OP→talk→news→ED）を `BroadcastEngine` が順次実行。
  失敗セグメントはスキップして放送継続、`critical: true`（既定で OP）は失敗で放送中止、Ctrl-C で即停止+完全静寂。
- LLM 確定: `gemini-3.1-flash-lite`（`GET /v1beta/models` で実在確認済み。代替: `gemma-4-26b-a4b-it`）。キー設定済み（`config/llm.local.yaml`）。
- コーナー基本パターン実装済み: テーマ → SongPicker（プレフライト選曲）→ 台本（DJ 二人、締めで曲振り）→ 発話（次行を先行合成）→ 一曲 → pause。
  テンプレは `config/corners.yaml`（`free_talk`）、DJ は `config/djs.yaml`（ずんだもん 3 / 四国めたん 2）。theme 差し替えで転用可。

## 4. ビルド・テスト・実行
```bash
cd ~/Develop/AIRadio/AIRadioMac
swift build
swift test                       # 件数は §3 参照
swift run AIRadioApp                            # 既定: メニューバー常駐（📻 から開始/停止）
AIRADIO_DEMO=tts         swift run AIRadioApp   # VOICEVOX 合成+再生
AIRADIO_DEMO=news        swift run AIRadioApp   # ニュース原稿を表示（音声なし、ネットだけ）
AIRADIO_DEMO=spotify-auth swift run AIRadioApp  # Spotify ログイン（PKCE、初回のみ。済）
AIRADIO_DEMO=spotify     swift run AIRadioApp   # 検索 + Web API 再生
AIRADIO_DEMO=theme       swift run AIRadioApp   # OP→ニュース(実データ)→ED の統一演出
AIRADIO_DEMO=corner      swift run AIRadioApp   # 会話コーナー（LLM 台本→DJ二人→一曲、要 Gemini キー）
AIRADIO_DEMO=broadcast   swift run AIRadioApp   # 番組 1 周（OP→トーク→ニュース→ED、Ctrl-C で停止）
```
※ `swift test` の件数は §3 を参照（上記コメントの件数は古いことがある）。

## 5. 環境・前提
- Swift 6.2 / swift-tools 6.0 / macOS 13。Xcode ライセンス同意済み。
- **VOICEVOX** をローカル起動（HTTP `127.0.0.1:50021`）しておくこと。
- **Spotify デスクトップアプリ起動 + Premium**。Web API 再生にはアクティブデバイスが必要。
- **Spotify OAuth は認証済み**（refresh トークンが Keychain `AIRadio.Spotify/refresh_token` に保存済み）。
  redirect_uri = `http://127.0.0.1:5543/callback`（Spotify Dashboard 登録済み、Windows 版と共用）。
  ※ Keychain アクセス時のプロンプトは、未署名 `swift run` だと再ビルドごとに出ることがある（署名 .app 化で解消）。
- **Gemini API キー** → `config/llm.local.yaml.sample` をコピーして `config/llm.local.yaml` に記入（gitignore 対象）。
- **API キー誤コミット防止フック有効**: `git config core.hooksPath scripts/git-hooks`（設定済み。clone し直したら再実行）。
  `*.local.yaml` のステージ、または `AIza...` パターンを含むコミットを拒否する。
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
- **Spotify デバイスはアイドルで stale になる**: 数分操作がないと device_id 指定の play でも 404 が返る。
  `WebApiSpotifyController.play` は transfer playback で起こして再試行（最大 3 回）する（S6 fix）。
- **LLM の文字数指示は下振れする**: 「およそ N 文字」だと 35% 程度短くなった。「N 文字以上、N×1.2 文字以内」と下限で縛る。
- **キャンセル済み Task 内では URLSession がリクエストを送らない**: 後始末の pause がそのままでは Spotify に
  届かず鳴りっぱなしになる。後始末はキャンセル非継承の新 Task で送る（`pauseIgnoringCancellation()`、S7）。
- **SIGINT ハンドラは main キューで**: トップレベル変数は MainActor 分離のため、`.global()` キューの
  DispatchSource ハンドラから触ると Swift 6 の実行時分離チェックで SIGTRAP クラッシュする（S7）。
- **再生先デバイスは「この Mac（type=Computer）」に限定**: `devices.first` への安易なフォールバックは
  スマホ等へ Spotify Connect 転送して別の場所で鳴らす事故になる。必要なら `spotify.local.yaml` の
  `device_name` で明示指定（S7）。
- **Keychain の refresh トークンをアプリ外で使わない**: PKCE はトークンローテーションするため、
  cURL 等で refresh すると保存済みトークンが無効化され `400 (invalid_grant)` になる。
  壊れたら `AIRADIO_DEMO=spotify-auth` で再ログイン（S7 で実際に踏んだ）。
- **声と音楽のラウドネス差**: VOICEVOX はほぼフルスケール出力、Spotify はスライダー%（対数的）+
  音量の正規化で減衰するため、素のままだと声 >> 音楽。tts.yaml `playback_volume` と
  themes/corners `volume` で揃える（S8）。停止後始末では音量もフルへ復元する。
- **再生切替直後の /me/player は前の曲のメタデータを返すことがある**: 曲長を即読みすると前の曲の
  長さで早切りする。URI の切替を確認してから読む（S10）。
- **曲が終わっても is_playing=true が返り続けることがある**: 「停止」だけを終了条件にすると
  打ち切り上限まで無音で粘る。停止 / 別トラック遷移 / 終端到達 / **位置の停滞** の OR で検知する
  （`waitForTrackToFinish`、S10）。
- **長文の一括 TTS 合成はデッドエアになる**: 700 字級の原稿は VOICEVOX 合成に 10〜15 秒かかる。
  発話は文単位チャンク（約 120 字）に分割し、先頭チャンクをイントロ中に・以降を再生中に
  先行合成するパイプラインで吸収（`ThemeSequencer.chunkAnnouncement`、S11）。

## 9. 仕様駆動ワークフロー（毎スライス）
1. `docs/specs/<feature>.md` を書く → 2. git commit → 3. Confluence『Mac版 仕様』にミラー（チェックリスト付き）→ 4. 実装 + `swift test` グリーン → 5. git commit/push → 6. チェック更新。
（コミット/プッシュはユーザー指示時。聴覚・視覚・ライブ確認はユーザーに依頼し、結果を反映。）

## 10. 次にやる S12 の候補（ユーザーと相談して決める）
- 番組の連続ループ / 標準番組構成 13 項目への拡張（新セグメント: DJ の気分・お便り・アーティスト特集等）
- 署名済み .app バンドル化（Keychain プロンプトの恒久解消、ログイン項目化への布石）
- ※ 再開時の最初の放送で「ニュースのダッキング直後に即発話されるか」を聴取確認（S11 の残確認）

## 11. 今後の検討課題（今はやらない）
- **Gemma フォールバック自動切替**（2026-06-12 検討、保留）: Gemini 429 時のみ `gemma-4-26b-a4b-it` に
  同一リクエストを流す緊急避難（スティッキーな状態なし、次コールはまた Gemini から）。
  検算の結果、消費は 1 コーナー 2 リクエスト ≒ 24h 連続放送でも 400 req/日・1 コール 4K トークン弱で、
  Gemini 無料枠（RPM 4K / TPM 4M / RPD 150K）はおろか Gemma 枠（RPM 30 / TPM 16K / RPD 14.4K）単独でも
  賄える規模のため**上限起因では発動しない**。価値があるとすれば Google 側障害時の可用性のみ。
  実装するなら: `FallbackLLMBackend`（primary/secondary ラッパ）+ `LLMError.rateLimited`
  （`E-LLM-RATE-LIMITED-001`、現状 429 は `apiFailed("HTTP 429")` に丸まっている）+
  `llm.yaml` に `fallback_model`。**注意: Gemma は `systemInstruction` 非対応の可能性が高い**
  （Gemma 3 世代までは reject）→ system をユーザープロンプト先頭に折り込む処理が必要。実装時に実 API で確認。
