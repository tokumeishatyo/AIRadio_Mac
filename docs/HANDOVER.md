# 引き継ぎ（再開ガイド）— ケイラボAIラジオ Mac版

> セッションをまたいで再開するための現在地まとめ。最終更新: 2026-06-14
> （**S0〜S19b すべてライブ確認済み・クローズ。次は「選曲多様化 A/B（反復回避・リングバッファ）」（未着手・優先度 低）**）。
> **次タスク = 選曲多様化 A/B（優先度 低）**: 通常コーナーの選曲が定番に固定する（真夜中のドア/栄光の架橋が複数放送で頻出）。原因＝`SongPicker` がステートレスで反復回避ゼロ＋先頭の再生可能曲を機械採用。
> **A（放送内・効果大）**＝①候補からランダム抽選（randomIndex 注入で先頭優先撤廃）②放送内既出 URI 除外（`SongRequest.excludeUris`、冒頭曲＋各コーナーで共有）③多様性指示＋既出曲名注入④候補数 5→8〜12。
> **B（放送またぎ）**＝`SongHistoryStore`（Core protocol＋Infra 実装・リングバッファ直近 N 曲 30〜50）。A は B 非依存で先行可。詳細・リスクは §10.5 と永続メモリ（airadio-mac-tech-decisions）。
> **仕様駆動で進める**: まず `docs/specs/<feature>.md` を書いてユーザーレビュー → 実装。
> 横断ルールは `../CLAUDE.md`、仕様は Confluence（下記）。S16〜S19b の採否・設計は §10.5 と永続メモリに記録済み。読み正確化の実機教訓は §8。

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

## 3. 進捗（S0〜S19b 完了・ライブ確認済み、次は 選曲多様化 A/B 未着手・優先度 低）
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
| S11 | ニュースの LLM 会話化（アナウンサー原稿） | ✅（ダッキング直後の即発話も聴取確認済み 2026-06-12） |
| S12 | 季節コンテキスト + テーマプール + お便りコーナー | ✅（ライブ確認済み 2026-06-12） |
| fix | フル再生の終端検知強化（stale 耐性）+ 全コーナー曲フル再生化 | ✅（実放送 1 周で全曲完走を確認 2026-06-13） |
| S13 | コーナー数駆動の番組生成 + ローリング準備 + ED で終了 + 番組の長さ UI | ✅（ライブ確認済み 2026-06-13） |
| S13.5 | 曜日替わりメインDJ + コーナー頭の二層化（挨拶整理・時報リード文）+ つむぎ追加 | ✅（ライブ確認済み 2026-06-13。日曜3人運営のみテストで担保・実放送未確認） |
| S14 | ゲストコーナー（最初のニュース直後に 1 回、ランダムゲスト＝テーマ専門家）+ ゲスト 10 名 | ✅（ライブ確認済み 2026-06-13） |
| S15 | アーティスト特集（ゲスト直後に 1 回、Spotify top-tracks で 3+3+1、生成ボタン+artist-gen.yaml）+ 会話の自然さ改善（連続感/ラスト明示/締めに{artist}）+fix2 | ✅（ライブ確認済み 2026-06-14） |
| S16 | DJの今日の気分（冒頭 greeting に一言）+ 常設コーナーのテーマ宣言リード文（free_talk lead_in を {theme} 化） | ✅（ライブ確認済み 2026-06-14） |
| S17 | DailyContext 拡張（曜日名 + 記念日の軽重 high/low）。`DailyCalendar` + `config/calendar.yaml`、CornerEngine/ArtistFeatureEngine に注入。+ 冒頭挨拶の時刻断定 fix | ✅（ライブ確認済み 2026-06-14） |
| S18 | ステーション・ジャーナル（週次リセットの長期記憶）。番組終了時にハイライト（ゲスト・特集）をLLM要約→`config/journal.local.yaml`→次回冒頭で振り返り | ✅（ライブ確認済み 2026-06-14） |
| S19a | 読み正確化①：VOICEVOX ユーザー辞書の冪等同期。`config/pronunciations.yaml`（表記→全角カナ読み[+accent]）を放送開始時に `/user_dict` へ冪等同期（追加・更新のみ・削除しない）。`VoicevoxUserDict`（fail-tolerant・NFKC+NFC 正規化）＋PRON カテゴリ。空白英字は効かない＝仕様（§8） | ✅（ライブ確認済み 2026-06-14、commit 3e36d47） |
| S19b | 読み正確化②：アーティスト読みの自動登録。「アーティスト一覧を生成」時にカナ読みも併出（`名前<TAB>カナ読み`）→ `artists.yaml`（`reading?`）→ S19a の辞書同期に合流（`VoicevoxUserDict.mergedEntries`、pronunciations 優先）。`parseEntries` 逸脱耐性（タブ無し=名前のみ救済/非カタカナは捨てる）。空白英字は効かない＝仕様 | ✅（ライブ確認済み 2026-06-14、commit 3037051） |

`swift test` = **354 件グリーン**。S19b 仕様 = `docs/specs/s19b-artist-reading.md`（Confluence S19b=39420033）。S19a 仕様 = `docs/specs/s19a-pronunciation-dictionary.md`（Confluence S19a=39616579）。S18 仕様 = `docs/specs/s18-station-journal.md`。S17 仕様 = `docs/specs/s17-daily-context.md`。S16 仕様 = `docs/specs/s16-mood-and-theme-leadin.md`。S15 仕様 = `docs/specs/s15-artist-feature.md` / Confluence S15=39419951。S14 仕様 = `docs/specs/s14-guest-corner.md` / Confluence S14=39485449。
- **S14**: `ProgramPlan` が**最初の news の直後に 1 回だけ**ゲスト talk を挿入（`includesGuestCorner`。N≥2/エンドレスのみ）。
  ゲストは `guests.yaml`（レギュラー4人を除く VOICEVOX 非レギュラー 10 名、**あんこもん＝語尾「もん」**）から
  **ランダム**（人選のみ。配置は固定）。台本では「テーマに詳しい専門家」として登場。`CornerFormat.guest`、
  `CornerContext.guest`/`PreparedCorner.guest`（ゲストは djs 外なので別持ち＋cast 末尾で run も話者解決）。
  リード文「{時刻}…次はゲストコーナーです。本日は{guest}さんを迎えて、{theme}について熱く語ってもらいます」は
  **{guest}/{theme} を準備時・時刻を発話直前に**展開。`BroadcastEngine.run(..., guests:)` が乱数選定＋fail-fast
  （ゲスト登場時のみ検証）。配置はコーナー自由配置の一例で、あえて最初のニュース直後に固定（spec §3 注記）。仕様 = `docs/specs/s13.5-weekday-main-dj.md` / Confluence S13.5=39419922（S13=39550977, S12=39223350, S11=39223320, S10=39223298, S9=39092225, S8=38993921, S7=38895618, S6=38731777）。
- **S13.5**: その日の**メインDJ（曜日替わり）が番組全体を仕切る**。`WeeklyCast`（program.yaml `weekly_cast`、先頭＝メイン。
  月ずん火めたん水つむぎ木ずん金めたん土つむぎ・日はずんメインの3人）。メインが OP/ED（themes.yaml `by_dj` の
  **DJ別固定口上**、口調込み）と時報リード文を読み、トークを主導（サブが相槌・ツッコミ）。ニュースは**龍星固定**。
  **春日部つむぎ追加**（speaker 8）。**コーナー頭の二層化**: 冒頭トークのみ時刻連動の挨拶＋出演者紹介、他は
  定型リード文「◯時◯分…〈コーナー名〉です」を**発話直前に時刻展開・合成**（ローリング準備のズレを受けない、s8/s11 と同方針）。
  配線: `CornerContext{castDjIds,greeting,leadIn}` を `prepare` に、`PreparedCorner.leadIn/leadInSpeakerId`、
  `BroadcastThemes.opening/ending` は `ThemedSegment`（per-DJ `DjSpiel`）。OP/ED 口上は main→anchor→先頭でフォールバック。
- **S13**: 番組は `ProgramPlan` がコーナー数 N から決定論的に生成（OP → 冒頭曲 →
  `[talk, talk, letter, news]` 繰り返し → ED。奇数の端数トークは直接 ED へ。エンドレスは ED なし）。
  program.yaml は **v2（部品宣言）**: talk/letter の corner_id・news の dj_id・`default_length`。
  準備は**ローリング方式**（実行中セグメントの先 2 つだけ。`BroadcastEngine.preparationWindow`）、
  **news は出現のたびに生成**。メニュー: 「**ED で終了**」（放送中のみ。直後のトークが準備完了済みなら
  それを流してから ED、お便り/ニュースは飛ばす）+「**番組の長さ**」（トーク 10/20/30 本/エンドレス、
  UserDefaults key `programLength` に保持、次の放送から反映）。状態表示はエンドレスで `(n/∞)`。
- **S12**: コーナーは corners.yaml の `themes:`（プール）から準備のたびにランダムにテーマを選ぶ
  （乱数は `CornerEngine` に注入可能）。`SeasonPhrases` が日付・季節コンテキスト
  （「今日は6月12日、梅雨の時期です。」）を生成し、台本・お便りの生成プロンプトに注入
  （「6 月に春めいて」ズレの根治）。**お便りコーナー**（`format: letter`）= ①お便り生成（LLM、
  1 行目ラジオネーム）→ ②リクエスト曲選定（お便り内容を選曲コンテキストに、プレフライトは従来どおり）
  → ③台本生成（読み上げ + 感想 + 曲振り）。進行ログに「テーマ: / お便り: ラジオネーム」を出力。
- **途中切り fix**: `waitForTrackToFinish` は曲長を **URI・位置と同一スナップショット**
  （`PlayerState.durationSeconds`）から読み、まとめ寝を **30 秒チャンク + 位置読み直し**に変更
  （詳細 §8）。診断ツール: `AIRADIO_DEMO=trackwatch` / `AIRADIO_SPOTIFY_LOG=1`。
- **「曲が 1 分強で終わる」の真因は仕様値だった**（2026-06-13）: ユーザー報告の途中切りは、
  コーナー締め曲の `play_seconds: 60`（60 秒かけて次へ進む設定）の動作。**全コーナーを
  `play_seconds: 0`（フル再生）に変更**（番組 1 周 ≒ 25 分前後に）。あわせて終端検知を強化
  （S12 fix-2）: 終了らしき観測（停止・別トラック遷移）は **0.5 秒おいた再観測で 2 回連続のとき
  だけ確定**（stale スナップショット対策）、復帰理由 `TrackFinishReason` を冒頭曲・コーナー曲とも
  「♪ 曲終了（検知: …）」として常時ログ、セグメント失敗時も即 pause（次セグメントとの音被り防止）。
- ニュース原稿は LLM 生成（`NewsScriptGenerator` + `LlmNewsScriptProvider`）: 固定の時報イントロ +
  本文（語り + コメント、約 2 分）+ 固定アウトロ。LLM 失敗時は S5 の定型テンプレに倒す。
  スタイル・長さは research.yaml の `llm_script:`、ペルソナは news セグメント dj_id（龍星）。
- ニュース原稿も先行準備（放送開始時に生成）。テーマ発話は**文単位チャンクのパイプライン合成**
  （長文を一括合成するとダッキング後に 10 秒超の合成待ちが出るため、S11 fix）。
- **切れ目ない放送**: 準備（選曲・LLM + 全行 TTS 事前合成・ニュース原稿）は前のセグメントの
  再生中に進む（S13 でローリング方式に）。OP は 1 曲目確定後に開始し `{first_song}` で曲振り。
  曲の終端は `waitForTrackToFinish`（URI 切替確認 → チャンク読み直し →
  停止/遷移/終端到達/位置停滞を**二重確認**で検知）。
- **既定起動 = メニューバー常駐**: `swift run AIRadioApp`（AIRADIO_DEMO なし）→ 📻 常駐（.accessory）。
  メニュー「放送を開始/停止/終了」。停止 = `BroadcastSession.stop()`（Task.cancel → S7 機構で完全静寂）。
  終了時も `applicationShouldTerminate` で stop してから閉じる。設定 YAML は開始のたびに読み直す。
- 時刻アナウンス: `TimePhrases`（{greeting}/{month}/{day}/{ampm}/{hour}/{hour12}/{minute}）を発話直前に展開。
  挨拶境界は Windows 踏襲（朝5-11/昼12-16/夜17-4）、文字列は themes.yaml の `greetings:`。
- ニュースは program.yaml の `dj_id: ryusei`（青山龍星=speaker 13）。テーマ系セグメントは dj_id で個別指定可。
- **音量・話速は config で調整**: 音楽=themes/corners の `volume`（現在 100）、声=tts.yaml の
  `playback_volume`（0〜1、現在 0.8）と `speed_scale`（話速、1.0=標準、現在 1.15）。
  いずれも YAML 編集のみ・再ビルド不要（ユーザーが好みに調整中）。
- 番組進行: `ProgramPlan`（program.yaml v2 の部品宣言 + 番組の長さから生成）を `BroadcastEngine` が
  順次実行。失敗セグメントはスキップして放送継続（+ 即 pause で音被り防止）、
  `opening.critical: true`（既定）は OP 失敗で放送中止、Ctrl-C / 停止で即停止+完全静寂。
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
AIRADIO_DEMO=trackwatch  swift run AIRadioApp   # 診断: フル再生の終端検知を全ログ観測（AIRADIO_TRACK_QUERY で曲指定）
AIRADIO_SPOTIFY_LOG=1    swift run AIRadioApp   # 診断: 放送中の全 Spotify 呼び出しを経過秒付きでログ
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
- **曲長は /me/player の同一スナップショットから読む**: 再生切替直後の `/me/player` は stale 応答を
  返すことがある（trackwatch で実測: play 完了後の 1 回目が前の曲・paused）。曲長だけ別リクエストで
  取り直すと**前の曲の曲長**を掴み、その位置で途中切りする（S12 で実際に踏んだ: OP BGM 183 秒 →
  3 分超の冒頭曲が 3 分すぎで切れる。3 分未満の曲は無症状なので気づきにくい）。
  `PlayerState.durationSeconds`（URI・位置と同一応答）を使う（S12 fix）。
- **長いまとめ寝は「読み直し基準」で**: `Task.sleep` はタイマー遅延（App Nap 等）で寝過ごす
  （実測: 350 秒の sleep が +23 秒）。`waitForTrackToFinish` は 30 秒チャンクで寝ては位置を
  読み直す方式（stale を掴んでも次の読み直しで自己修正、曲終了後のデッドエアもほぼゼロに。
  「停止」に見えても 1 拍おいて再確認してから確定する）。実測: 354.9 秒の曲で 354.7 秒で復帰（S12 fix）。
- **終了らしき観測は必ず二重確認**: /me/player の stale スナップショットは再生中のポーリングにも
  紛れ得る。「停止 / 別トラック遷移」を 1 回の観測で確定すると、その瞬間の pause で途中切りになる。
  0.5 秒おいた再観測で同じ結論のときだけ終了と確定する（`waitForTrackToFinish`、S12 fix-2）。
- **「途中で終わる」報告はバグの前に設定仕様を疑う**: コーナー締め曲が 1 分強で切れる報告の真因は
  `play_seconds: 60` という意図された設定値だった（2026-06-13）。症状からバグを推理する前に、
  その音を出している経路の設定値・仕様を先に確認する。
- **VOICEVOX ユーザー辞書の癖（S19a、実機 v0.25.2）**: ①登録は `POST /user_dict_word` の
  **クエリパラメータ方式**（body=nil）。`accent_type` は API 必須（未指定でも 0 を送る）、
  `pronunciation` は**全角カタカナ限定**（ひらがな・半角カナは 422）。②サーバが `surface` を
  **全角正規化して保存・返却**（`Mr.Children`→`Ｍｒ．…`）→ raw 突合不可、**両辺 NFKC** で突合
  （でないと毎放送 POST で二重登録＝冪等破綻）。③**NFKC（`precomposedStringWithCompatibilityMapping`）
  単体は半角濁点を `ト＋U+3099` のまま残す**→ NFC（`precomposedStringWithCanonicalMapping`）を
  重ねて `ド`(U+30C9) に合成。比較は pronunciation＋accent_type のみ（priority/word_type のサーバ既定ズレで誤 PUT 回避）。
  ④**空白を含む純英字 surface は形態素解析で照合されず効かない**（`SEKAI NO OWARI`＝アルファベット棒読み。
  効くのは日本語・漢字交じり・空白なし英字単語・記号結合英字 `Mr.Children`）→ 通称カナ運用で割り切り。
  ⑤uuid 不在は 404 でなく **422**。⑥**public struct は暗黙 Sendable にならない**（`VoicevoxUserDict` に
  `: Sendable` を明示しないと `BroadcastStack` の暗黙 Sendable が壊れる）。⑦`HTTPClient` に DELETE が無い→
  削除しない設計が「手動登録を保護」要件とも一致。

## 9. 仕様駆動ワークフロー（毎スライス）
1. `docs/specs/<feature>.md` を書く → 2. git commit → 3. Confluence『Mac版 仕様』にミラー（チェックリスト付き）→ 4. 実装 + `swift test` グリーン → 5. git commit/push → 6. チェック更新。
（コミット/プッシュはユーザー指示時。聴覚・視覚・ライブ確認はユーザーに依頼し、結果を反映。）

## 10. ロードマップ S12〜S15（ユーザーと合意済み 2026-06-12。変更時は要相談）
番組拡張の全体構想（ユーザー発案）: テーマプール付きトークを軸に、お便り・ゲスト・アーティスト特集を
織り交ぜ、コーナー数で番組の長さを決める。**順に 1 スライスずつ**。

- **S12（✅ 完了・ライブ確認済み 2026-06-12）**: 季節コンテキスト注入 + テーマプール + お便りコーナー。
  詳細 = `docs/specs/s12-themed-talk-letters.md`。
- **S13（✅ 完了・ライブ確認済み 2026-06-13）**: コーナー数駆動の番組生成 + ローリング先行準備 +
  ED ボタン + 番組の長さ UI。詳細 = `docs/specs/s13-program-generation.md`（§3 に要約）。
- **S13.5（✅ 完了・ライブ確認済み 2026-06-13）**: 曜日替わりメインDJ + コーナー頭の二層化
  （挨拶整理・時報リード文）+ つむぎ追加。詳細 = `docs/specs/s13.5-weekday-main-dj.md`（§3 に要約）。
  ※発話の波ダッシュ「〜」は VOICEVOX で途切れるため TTS 境界で長音「ー」に正規化（`VoicevoxTTS.normalizeForSpeech`）。
- **S14（✅ 完了・ライブ確認済み 2026-06-13）**: ゲストコーナー（最初のニュース直後に 1 回、ランダムゲスト＝テーマ専門家）。
  詳細 = `docs/specs/s14-guest-corner.md`（§3 に要約）。あんこもん語尾「もん」を確認用にプール固定して聴取確認済み。
- **S15（🚧 実装完了・ライブ確認待ち 2026-06-14）**: アーティスト特集（**ゲストコーナーの直後**に 1 回）。
  確定: 実行時は `artists.yaml` からランダム 1 組 → **Spotify top-tracks** で最大 7 曲を取得（LLM 曲名生成は不採用）→
  **3+3+1**（導入 → 3 曲紹介 → 3 曲連続 → 感想 → 3 曲紹介 → 3 曲連続 → 感想(短) → 1 曲紹介 → 1 曲 → 固定の締め）。
  プールは**メニュー「アーティスト一覧を生成」ボタン**で作成（出荷時は空＝特集スキップ・放送と相互排他・常に全置換）。
  **ジャンル/件数は `config/artist-gen.yaml`** で変更（既定 邦楽・100 名）。曲 3 未満/プール空はスキップ（E-ART-*）。
  詳細 = `docs/specs/s15-artist-feature.md`（Confluence S15=39419951）。実装 = commit `cb11121`。
- **S15 はすべてライブ確認済み・クローズ（2026-06-14）**: 構造・生成ボタン・曲被りfix・語尾fix・会話の自然さ改善3点＋fix2。正規 config 復元・コミット/プッシュ済み。
  S13.5 の日曜3人運営はテスト担保・実放送は日曜に確認できれば（任意）。
- **語尾混線 fix（commit `ca08625`、push 済み）**: 日曜3人（ずんだもんメイン）で春日部つむぎがメインの「のだ」に語尾伝染していた
  （一人称「あーし」は正）。台本プロンプトに「各 DJ は自分の語尾だけ使う・メインの語尾を他に伝染させない」制約を追加（通常トーク＋
  アーティスト特集の両方）＋ djs.yaml で tsumugi の語尾を明記。**2026-06-14 日曜にライブ確認済み（つむぎの語尾が正常化）。**
  ※ S15 アーティスト特集**ブロック本体**: 構造はライブ確認済み（ゲスト直後に1回・口上・3+3+1・曲間無音なし）。
  生成ボタンも実動作OK（artists.yaml に100組生成）。**曲被りバグを発見→修正済み**（commit `406b070`、push 済み）:
  グループ最終曲の後に pause を入れ、`play_seconds>0` でも感想（DJ発話）が鳴ったままの曲に被らないように
  （グループ内の連続再生は維持）。**fix は実放送再確認済み（2026-06-14、曲被り解消）。**
  **特集の会話の自然さ改善・確定3点（完了・ライブ確認済み 2026-06-14、296テスト）**: ①2回目以降のグループ紹介に連続感
  （`groupIntro(tracks:index:total:)` 化＋`makeArtistFeatureRequest` で `index>0` なら**進行中の特集を「引き続き◯◯の曲を」で続ける**。1回目・単一グループは従来どおり）
  ②最後のグループ（`index==total-1 && index>0`）に「最後はこの N 曲」のラスト明示（曲数連動。共通の締め制約から「最後は」を外し1回目/単一への『最後』混入を回避）
  ③`ArtistFeatureParams.outroLine` 既定を「以上、{artist}特集でした。」化＋prepare で `artist.name` 置換（leadInと同型・リテラルもno-op後方互換）、corners.yaml も {artist} 化。
  **fix2（ライブ追加調整）**: 2回目以降の枕が「続いては◯◯特集」だと特集が新規開始するように聞こえる→「この特集はすでに進行中…新規開始の言い方は禁止、『引き続き◯◯の曲を』で続ける」に変更。
  敵対レビュー3観点 → 確定指摘は最後グループ複数曲ケースのテスト欠落のみ（実装は正しい）→テスト追加で解消。**詳細は永続メモリ（airadio-mac-tech-decisions）**。
  ※ config は正規値に復元済み（temp 短縮は破棄）。`artists.yaml` の生成済み100組はローカル保持（出荷時=空、コミットしない）。
- 保留中の検討課題は §11（Gemma フォールバック）。署名 .app バンドル化は S15 以降の候補。
  ※「コーナー頭の毎回自己紹介の抑制」は **S13.5 で対応済み**（冒頭のみ挨拶＋時報リード文化）。
  ※ED のショート掛け合い化（BGM 上の複数話者発話）は S13.5 でスコープ外として残置（将来の小改善）。

## 10.5 S16 以降ロードマップ（2026-06-14 確定 — 標準13項目の洗い出し→採否トリアージ済み）
要件定義§7の標準13項目を現実装と突合（敵対検証付き workflow で分析）。詳細な根拠・全項目の判定は永続メモリ
（airadio-mac-tech-decisions）に記録。**採用したスライス**:
- **S16** ✅ ライブ確認済み・クローズ（2026-06-14、297テスト、commit `a874aeb`、spec=`docs/specs/s16-mood-and-theme-leadin.md`、Confluence S16=39551023）: ③DJの今日の気分
  （冒頭 greeting プロンプトに「今日の気分を一言→本題へ橋渡し」を追加＝`DialogueScriptGenerator` の greeting 分岐）＋
  常設コーナーのリード文をテーマ宣言化（「フリートークのコーナーです」→「{theme}について話そうと思います」。**config 1行のみ**＝
  `{theme}` 置換は `CornerEngine.prepare` の既存機構。冒頭は greeting で lead_in 不使用なので①と重複しない）。**別テンプレ建ては不要**。
- **S17** ✅ ライブ確認済み・クローズ（2026-06-14、309テスト、commit `636315b`、spec=`docs/specs/s17-daily-context.md`、Confluence S17=39485487）: DailyContext 拡張
  （季節+日付に**曜日名・記念日**を追加注入）。新 Core `DailyCalendar`（曜日名+記念日、`context()` が文を生成、記念日は同日複数なら high 優先で代表1件）、
  Infra `DailyCalendarLoader`、config = **`config/calendar.yaml`**（要件の `anniversaries.yaml` から改名＝曜日名も持つ。要件定義 v1.2 §8 も calendar.yaml へ更新済み）。
  CornerEngine/ArtistFeatureEngine に `dailyCalendar: DailyCalendar = .standard` を注入（既存呼び出しは default で無影響、`SeasonPhrases.dateContext` 呼び出しを置換）。
  **軽重**: `high`(祝日級)=各コーナーのプロンプトに「番組を通して…意識して織り込む」（波及）／`low`(軽い暦)=「軽く触れる程度・深入りしない」／なし=曜日+季節のみ。news は対象外（dateContext 非注入）。
  **S16 の今日の気分は同じ dateContext を使うので自動で厚みが増す**。残: 実放送で曜日・季節・記念日の軽重を聴取確認。
- **S18** ✅ ライブ確認済み・クローズ（2026-06-14、324テスト、commit `ddcfae3`、spec=`docs/specs/s18-station-journal.md`、Confluence S18=39616549）: ステーション・ジャーナル（長期記憶）。
  番組終了時にハイライト（**ゲスト・特集のみ**＝確定A）を LLM 要約 → `config/journal.local.yaml`（gitignore）に永続化 → 次回**冒頭コーナーのみ**で軽く振り返り。
  新 Core: `StationJournal`（weekKey=ISO週・`appended` が週替わりリセット＋maxEntries7リングバッファ）/ `JournalStore` protocol / `BroadcastDigest` / `JournalSummarizer`（LLM＋失敗時フォールバック・throwしない）。
  Infra `YamlJournalStore`。`BroadcastEngine` に optional 注入（nil=無効）＝load→冒頭へ journalContext 注入、**正常終了のみ**保存（停止/キャンセルは記録しない＝確定D）。
  **週次リセット**（放送開始時に当週と違えば破棄＝日曜まで貯め月曜クリア）＋**ファイル削除で即クリア**。完全 fail-tolerant（要約/保存失敗でも放送は止めない）。残: 実放送で「翌回の冒頭に前回の振り返り」を確認。
- **S19a（読み正確化①＝VOICEVOX ユーザー辞書）✅ ライブ確認済み・クローズ（2026-06-14、342テスト、commit `3e36d47`、spec=`docs/specs/s19a-pronunciation-dictionary.md`、Confluence S19a=39616579）**:
  `config/pronunciations.yaml`（表記→全角カナ読み[+accent]）を放送開始時に `/user_dict` へ冪等同期（追加・更新のみ・削除しない）。
  新型 `VoicevoxUserDict`（struct・Sendable・fail-tolerant＝throw しない・NFKC+NFC 正規化）＋`PronunciationsConfigLoader`＋Core `PronunciationEntry`、新カテゴリ **PRON**。
  実機教訓は §8（全角正規化突合・NFKC 濁点・空白英字不可・accent_type 必須・422・Sendable）。**空白英字バンド名は通称カナ運用で割り切り**（ユーザー判断）。
- **S19b（読み正確化②＝アーティスト読み自動登録）✅ ライブ確認済み・クローズ（2026-06-14、354テスト、commit `3037051`、spec=`docs/specs/s19b-artist-reading.md`、Confluence S19b=39420033）**:
  「アーティスト一覧を生成」時にカナ読みも併出（`名前<TAB>カナ読み`）→ `artists.yaml`（`reading?`）→ S19a の同期に合流（`VoicevoxUserDict.mergedEntries`、pronunciations 優先・NFKC 突合）。
  `ArtistProfile.reading`（後方互換）／`parseEntries` 逸脱耐性（タブ無し＝名前のみ救済／最初のタブのみ／非カタカナ読みは捨てる・半角カナは NFKC 全角化）／`write` は reading 非 nil のみ出力。読み検証は S19a の `normalizePronunciation`/`isKatakana` 再利用。
  **発見**: Yams は `YAMLEncoder` で artists.yaml の日本語を `\uXXXX` エスケープして書く（name も同様・S15 から既存挙動・デコード往復は正常）。空白英字バンド名は効かない＝仕様。可読性向上（エスケープ無効化）は将来の小掃除候補。
- **選曲多様化（優先度 低・リングバッファで確定）**: 通常コーナーの選曲が定番に固定（真夜中のドア/栄光の架橋が複数放送で5回）。
  原因（敵対検証済）= `SongPicker` がステートレスで反復回避ゼロ＋「先頭の再生可能曲を機械採用」で定番が必ず勝つ。
  **A（放送内・小〜中、単独でも効果大）**=①候補からランダム抽選（randomIndex 注入で先頭優先撤廃）②放送内既出 URI セット除外
  （`SongRequest.excludeUris`、冒頭曲＋各コーナーで共有）③多様性指示＋既出曲名注入④候補数 5→8〜12。
  **B（放送またぎ・中〜大）**=`SongHistoryStore`（Core protocol＋Infra 実装、**リングバッファ直近 N 曲 30〜50**）。A は B に非依存で先行可。

**不採用**: ⑫今日最後の曲（ED前コーナーの締め曲で足りる）／リスナー投稿系すべて（§2投稿フォーム UI・⑥⑩お便り本物優先・
§9曲リクエスト → お便りは**架空生成のみで割り切り**）／DailyTheme（本日のテーマ UI入力）／常設コーナー2の別テンプレ建て。
**現状維持**: ニュース固定2回（N依存でOK）／TalkBlock 3〜5ターン粒度（コーナー単位生成で十分）／役割3区分モデル化（必要時に同梱）。

**次アクション（再開時）**: ① 要件定義 SoT（Confluence 37519362）に採否反映（§7に③・リード文、§8にジャーナル週次リセット・
DailyContext 軽重、§11不採用一覧に4件）→ ハブ整合 → ② **S16 の仕様書（docs/specs）から着手**。番号付けは流動
（読み正確化＝中・選曲多様化A＝低だが“毎放送の不満を消す”枠なので早め差し込み可）。

## 11. 今後の検討課題（今はやらない）
- **VOICEVOX エンジンの自動起動管理**（2026-06-14・完成形監査、要件§11 後回し）: 現状は利用者が手動起動（BYO、§5）。未起動時は
  `TtsError.unreachable`→「VOICEVOX を起動してください」で促す。将来 `NSWorkspace.open` 等で VOICEVOX.app を自動起動する余地
  （config/tts.yaml に任意の `launch_command` を足す Windows 踏襲案）。要件 v1.3 で §3「自動起動管理」を §11 後回しに整理済み。
- **状態表示行のセグメント種別の日本語化**（2026-06-14・完成形監査、要件§11 後回し）: `MenuBar.swift` の状態行が
  `SegmentKind.rawValue`（opening/song/talk/news/artistFeature/ending＝英語）をそのまま表示（「放送中: artistFeature (n/m)」）。
  `SegmentKind` に日本語表示名（または §4-1 準拠で corners.yaml 等から引く）を 1 箇所足して差し替える小改善。s9 受け入れ条件には含まれずブロッカーではない。
- **Windows 版再実装の可搬性**（2026-06-14 監査済み・別途まとめ予定）: 将来 Windows 版を別言語で再作成予定。理想
  「config 持参で同じ番組」は**部分的にしか成立しない**（LLM プロンプトが Core にハードコード＝唯一の綻び。番組名
  「ケイラボAIラジオ」直書き4箇所は最小修正候補）。Core+protocol 設計自体は cross-platform に正解。**本 Mac プログラム
  完成後に「config移植可 vs 要再実装」の Windows 移植ガイドを docs に作成**する。3層マップ・ブロッカー・prompts.yaml
  外部化の段階案は永続メモリ `airadio-windows-portability` に記録済み（再開時の素材）。
- **Gemma フォールバック自動切替**（2026-06-12 検討、保留）: Gemini 429 時のみ `gemma-4-26b-a4b-it` に
  同一リクエストを流す緊急避難（スティッキーな状態なし、次コールはまた Gemini から）。
  検算の結果、消費は 1 コーナー 2 リクエスト ≒ 24h 連続放送でも 400 req/日・1 コール 4K トークン弱で、
  Gemini 無料枠（RPM 4K / TPM 4M / RPD 150K）はおろか Gemma 枠（RPM 30 / TPM 16K / RPD 14.4K）単独でも
  賄える規模のため**上限起因では発動しない**。価値があるとすれば Google 側障害時の可用性のみ。
  実装するなら: `FallbackLLMBackend`（primary/secondary ラッパ）+ `LLMError.rateLimited`
  （`E-LLM-RATE-LIMITED-001`、現状 429 は `apiFailed("HTTP 429")` に丸まっている）+
  `llm.yaml` に `fallback_model`。**注意: Gemma は `systemInstruction` 非対応の可能性が高い**
  （Gemma 3 世代までは reject）→ system をユーザープロンプト先頭に折り込む処理が必要。実装時に実 API で確認。
