# S10 — 切れ目ない放送（冒頭曲セグメント + コーナーの先行準備）

## 1. 概要
OP 直後にトークコーナーの LLM 処理（選曲 + 台本生成、計 10 秒前後）による**放送中の無音（デッドエア）**が
発生していた。これを解消する:

1. **冒頭曲セグメント（`type: song`）を新設**: 放送開始をトリガーに「本日の 1 曲目」を LLM 選曲 +
   プレフライトで確定（**放送開始前の無音は許容**）→ 確定後に OP 開始 → OP の締めで曲振り → 1 曲目を再生。
2. **トークコーナーの先行準備（プリフェッチ）**: 放送開始時に全 talk セグメントの準備
   （選曲 + 台本生成）をバックグラウンドで並行起動。各コーナーの番が来たら準備済み台本で即開始。
   1 曲目が流れている間に台本が完成している。

原則: **放送開始前の無音は許容、放送中の長い無音はゼロにする**（LLM は HTTP のみで音声と干渉しない）。

## 2. スコープ

**in**:
- Core `SongRequest` + `SongPicking` protocol: SongPicker をコーナー専用から汎用化
  （`context`（用途の説明）/ `promptHint` / `fallbackTrackUri`）。`SongPicker` が準拠。
- Core `PreparedCorner`（corner + 確定曲 + 台本）+ `CornerRunning` を 2 段に分割:
  - `prepare(corner:djs:)`: LLM 処理のみ（音を出さない。失敗時も pause 不要）
  - `run(prepared:djs:)`: 発話 + 一曲 + pause（従来の本番部分）
  - 互換の `run(corner:djs:)` は extension（prepare + run、単発デモ用）
- `ProgramSegment` に `song` 種別 + `SongSegmentSpec`（prompt_hint / fallback_track_uri（必須）/
  volume / play_seconds、program.yaml に記述）
- `BroadcastEngine` のパイプライン化:
  - 放送開始時に全 song の選曲・全 talk の準備を**並行 Task で起動**
  - 最初の song の確定を待ってから OP を開始（`{first_song}` プレースホルダが使えるように）
  - `{first_song}` = 「<アーティスト>で、「<曲名>」」（不明時は「本日の一曲」）。全テーマ文言で使用可
  - song セグメント: 確定曲を再生（`play_seconds`、0 = フル）→ pause → 次へ
  - talk セグメント: 準備 Task の完了を待って `run(prepared:)`（通常は待ち時間ゼロ）
  - **停止時は準備 Task も確実にキャンセル**（`withTaskCancellationHandler`。完全静寂は従来どおり）
  - 選曲失敗は fallback 曲に倒して放送継続。準備失敗（台本）は従来どおりスキップ（critical は中止）
- config: program.yaml = OP → **song** → talk → news → ED の 5 セグメント構成 /
  themes.yaml の OP 文言末尾に曲振り（`{first_song}`）
- App: 配線に SongPicker を追加（既存 LLM / searcher を共用）
- テスト: SongPicker 汎用化 / prepare・run 分割 / song セグメント再生とフォールバック /
  先行準備の利用 / `{first_song}` 展開 / 停止時の準備キャンセル / ローダ（song 必須項目）

**out（後続）**:
- ニュース原稿のプリフェッチ（取得 1 秒未満のため不要と判断）/ ニュースの LLM 会話化
- 連続ループ・他の 13 項目セグメント

## 3. 番組の流れ（変更後）

```
放送開始 ─→ [無音許容] 1曲目の選曲+プレフライト（並行: 全talkの選曲+台本生成を起動）
        └→ OP（テーマ演出、締めで「それでは聴いてください。{first_song}。」）
        └→ 本日の1曲目（フル再生。この間に台本生成が完了）
        └→ フリートーク（準備済み台本で即開始）
        └→ ニュース天気 → ED
```

## 4. 設定（変更・追加）

```yaml
# program.yaml
segments:
  - type: opening
    critical: true
  - type: song                       # 冒頭曲（本日の 1 曲目）
    song_prompt_hint: "一日の始まりや番組の幕開けに合う、前向きで広く知られた曲"
    fallback_track_uri: "spotify:track:..."   # 必須
    volume: 100
    play_seconds: 0                  # 0 = フル再生
  - type: talk
    corner_id: free_talk
  - type: news
    dj_id: ryusei
  - type: ending

# themes.yaml（opening.announcement 末尾に追記）
"…なのだ。それでは聴いてください。{first_song}。"
```

## 5. 受け入れ条件
- `swift build` / `swift test` 全グリーン
- `swift run AIRadioApp` →「放送を開始」で、**OP の締めで実際に流れる曲が曲振りされ、OP →
  1 曲目 → フリートークがほぼ無音なく連続する**（ユーザー確認。コーナー間の 1〜2 秒の間は演出範囲）
- 1 曲目再生中のコンソールに台本生成完了のログが出る（先行準備の確認）
- 放送中の停止・終了の挙動は従来どおり（即静寂）
- エラーコード追加なし
