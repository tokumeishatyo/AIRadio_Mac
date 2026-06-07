# S2 — Spotify ハイブリッド（Web API 検索 + AppleScript 再生）

## 1. 概要
曲を扱う土台。**検索・再生可否確認は Spotify Web API（Client Credentials、ユーザー OAuth 不要）**、
**再生・音量・シーク・停止・状態取得は AppleScript（ローカル Spotify.app 直接、認証ゼロ）** のハイブリッド。
HTTP は `HTTPClient`、AppleScript は `AppleScriptRunner` 抽象越しにして単体テスト可能にする。

## 2. スコープ

**in**:
- `SpotifyConfig` + `SpotifyConfigLoader`（client_id / client_secret / market）。`config/spotify.local.yaml`（gitignore）+ `.sample`
- `SpotifyWebSearcher`（actor, `TrackSearcher`）— Client Credentials トークン取得（キャッシュ + 期限）→ search / tracks（isPlayable）
- `AppleScriptRunner` protocol + `OsascriptRunner`（`/usr/bin/osascript` 経由）
- `AppleScriptSpotifyController`（`SpotifyController`）— play / pause / setVolume / seek / playerState
- エラー `SpotifyError` に `authFailed` / `searchFailed` 追加
- `AIRadioApp` に Spotify デモ（`AIRADIO_DEMO=spotify`）: 検索 → プレフライト → 再生 → 状態 → 停止
- テスト: SpotifyWebSearcher（fake HTTP、トークンキャッシュ、検索パース、isPlayable、authFailed）/ AppleScriptSpotifyController（生成スクリプト検証 + 状態パース）/ SpotifyConfigLoader
- `docs/specs/error-codes.md` 追記

**out（後続）**:
- 統一テーマエンジン（ダッキング演出）→ S3
- コーナー間曲・プレフライト統合 → S4
- LLM 選曲ヒント → S6

## 3. Web API（Client Credentials）
- トークン: `POST accounts.spotify.com/api/token`（`Authorization: Basic base64(id:secret)`, `grant_type=client_credentials`）→ access_token / expires_in。期限 -30s でキャッシュ。
- 検索: `GET api.spotify.com/v1/search?q=&type=track&limit=&market=`（`Authorization: Bearer`）
- 再生可否: `GET api.spotify.com/v1/tracks/{id}?market=` の `is_playable`

## 4. AppleScript（ローカル制御）
- 再生: `tell application "Spotify" to play track "<uri>"`
- 音量: `set sound volume to <0-100>` / シーク: `set player position to <sec>` / 停止: `pause`
- 状態: `player state` / `id of current track` / `player position` を区切り文字列で返しパース
- 初回実行時に macOS の「自動化」許可（TCC）プロンプトが出る

## 5. 受け入れ条件
- `swift build` / `swift test` 全グリーン（ネットワーク・Spotify 非依存、fake で検証）
- 実機 `AIRADIO_DEMO=spotify swift run AIRadioApp` で検索結果が出て、曲が再生され停止する（ユーザー確認、要 client_secret + Spotify 起動 + 自動化許可）

## 6. エラーコード（追記）
| コード | 発生条件 |
|---|---|
| `E-SPT-AUTH-FAILED-001` | Client Credentials トークン取得失敗 |
| `E-SPT-SEARCH-FAILED-001` | 検索 / トラック取得失敗 |
（既存 `E-SPT-API-FAILED-001` を AppleScript 実行失敗に流用、`E-SPT-NO-DEVICE-001` は将来用）
