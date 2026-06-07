# S4 — Spotify Web API 再生 + OAuth（PKCE）

## 1. 概要
S2 の AppleScript 再生は `play track` のクセで曲切替時に前曲が一瞬鳴る（Windows 版は Web API の
アトミック再生で発生しなかった）。聞き心地のため再生も **Spotify Web API** に統一する。
認証は **Authorization Code + PKCE**（公開クライアント、client_secret 不要）。検索も同じユーザー
トークンに統一し、Client Credentials を廃止する。refresh トークンは **macOS Keychain** に保管。

## 2. スコープ

**in**:
- `SpotifyTokenProvider` protocol（Infra）+ `SpotifyAuth`（actor）: PKCE 認可・トークン更新・キャッシュ
- `TokenStore` protocol + `KeychainTokenStore`（Security framework）
- `PKCE`（verifier / challenge, SHA256 + base64url, CryptoKit）
- `LoopbackServer`（Network framework, `127.0.0.1:<port>/callback` で認可コード受領）
- `WebApiSpotifyController`（`SpotifyController` を Web API で実装: play/pause/setVolume/seek/playerState/duration）
- `HTTPClient` に `put` 追加
- `SpotifyWebSearcher` を `SpotifyTokenProvider` 利用に refactor（CC 廃止）
- `SpotifyConfig`: client_id / redirect_uri / market（client_secret 廃止）
- `SpotifyError.authRequired` 追加
- `ThemeSequencer`: AppleScript 用のミュート＆切替待ち回避ロジックを撤去（Web API アトミック再生で不要）
- App デモ: `AIRADIO_DEMO=spotify-auth`（初回ログイン）/ `spotify` / `theme` を Web API 経路に
- テスト: SpotifyAuth（更新 / authRequired）/ PKCE / WebApiSpotifyController / SpotifyWebSearcher / SpotifyConfigLoader

**out（後続）**:
- メニューバー UI からの「Spotify 接続」操作 → S7
- AppleScriptSpotifyController は代替実装として残置（既定は Web API）

## 3. 認証フロー（PKCE）
1. verifier 生成 → challenge = base64url(SHA256(verifier))
2. ブラウザで `https://accounts.spotify.com/authorize`（client_id / response_type=code / redirect_uri /
   code_challenge_method=S256 / code_challenge / scope=user-read-playback-state user-modify-playback-state）
3. `LoopbackServer` が `http://127.0.0.1:5543/callback?code=...` を受領
4. `POST /api/token`（grant_type=authorization_code, code, redirect_uri, client_id, code_verifier）→ access/refresh
5. refresh トークンを Keychain 保管。以降は refresh_token で無音更新（期限 -30s でキャッシュ）

## 4. 再生（Web API、Premium + アクティブデバイス必須）
- play: `GET /v1/me/player/devices` でデバイス解決 → `PUT /v1/me/player/play?device_id=`（body `{"uris":[uri]}`）
- pause: `PUT /v1/me/player/pause` / volume: `PUT /v1/me/player/volume?volume_percent=` / seek: `PUT /v1/me/player/seek?position_ms=`
- state: `GET /v1/me/player`（is_playing / progress_ms / item.uri / item.duration_ms）

## 5. 受け入れ条件
- `swift build` / `swift test` 全グリーン（ネットワーク・Keychain 非依存、fake で検証）
- 実機: `AIRADIO_DEMO=spotify-auth` でログイン成功 → `AIRADIO_DEMO=theme` で**ブリップ・切替無音なし**の演出（ユーザー確認）

## 6. エラーコード（追記）
| コード | 発生条件 |
|---|---|
| `E-SPT-AUTH-REQUIRED-001` | 未ログイン（refresh トークンなし）。`spotify-auth` での認可が必要 |
（既存 `E-SPT-AUTH-FAILED-001` をトークン交換/更新失敗、`E-SPT-NO-DEVICE-001` をデバイスなしに流用）
