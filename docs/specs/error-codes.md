# エラーコード台帳

形式: `E-<CAT3>-<DETAIL>-<NNN>`。Swift では enum の case に安定コード文字列を持たせる（`RadioError.code`）。

カテゴリ: CFG（設定）/ RTM（実行時）/ SPT（Spotify）/ TTS（VOICEVOX）/ LLM（Gemini・Gemma）/
NEWS（News RSS）/ WX（気象庁天気）/ RES（リサーチ共通）。

| コード | カテゴリ | 発生条件 | 導入スライス |
|---|---|---|---|
| `E-SPT-NO-DEVICE-001` | SPT | 再生可能な Spotify がない | S0 |
| `E-SPT-API-FAILED-001` | SPT | Spotify 操作の一般失敗 | S0 |
| `E-CFG-MISSING-FIELD-001` | CFG | 設定の必須フィールド欠落 | S0 |
| `E-TTS-UNREACHABLE-001` | TTS | VOICEVOX に接続できない | S1 |
| `E-TTS-SYNTHESIS-FAILED-001` | TTS | 合成 API がエラー応答 | S1 |
| `E-RTM-AUDIO-PLAYBACK-001` | RTM | 音声再生の開始に失敗 | S1 |
| `E-SPT-AUTH-FAILED-001` | SPT | Client Credentials トークン取得失敗 | S2 |
| `E-SPT-SEARCH-FAILED-001` | SPT | 検索 / トラック取得失敗 | S2 |
| `E-SPT-AUTH-REQUIRED-001` | SPT | 未ログイン（refresh トークンなし）。PKCE 認可が必要 | S4 |
