# エラーコード台帳

形式: `E-<CAT3>-<DETAIL>-<NNN>`。Swift では enum の case に安定コード文字列を持たせる（`RadioError.code`）。

カテゴリ: CFG（設定）/ RTM（実行時）/ SPT（Spotify）/ TTS（VOICEVOX）/ LLM（Gemini・Gemma）/
NEWS（News RSS）/ WX（気象庁天気）/ RES（リサーチ共通）/ ART（アーティスト特集）/ JNL（長期記憶）。

ART は **実行時の特集スキップ専用**（fail-tolerant・throw しない・診断ログ用の安定コード）。
特集の設定不正（コーナー不在・id 衝突・artists.yaml 破損）は既存 CFG（`E-CFG-MISSING-FIELD-001`）に寄せる。

JNL（ステーション・ジャーナル、S18）は **完全 fail-tolerant**: 要約 LLM 失敗・ファイル破損・保存失敗のいずれも
握り潰して放送を継続する（専用の throw コードは設けず、診断はログのみ）。記録は ED で正常終了した回のみ。

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
| `E-NEWS-FETCH-FAILED-001` | NEWS | Google News RSS 取得・解析失敗 | S5 |
| `E-WX-FETCH-FAILED-001` | WX | 気象庁 取得・解析失敗 | S5 |
| `E-LLM-KEY-MISSING-001` | LLM | Gemini API キー未設定（llm.local.yaml なし / api_key 空） | S6 |
| `E-LLM-API-FAILED-001` | LLM | generateContent が非 2xx / 通信失敗 | S6 |
| `E-LLM-EMPTY-RESPONSE-001` | LLM | LLM 応答にテキストがない | S6 |
| `E-LLM-SCRIPT-PARSE-FAILED-001` | LLM | LLM 応答が台本として解釈できない（4 行未満） | S6 |
| `E-RTM-SEGMENT-FAILED-001` | RTM | 放送セグメントが実行時エラーで中断（スキップして継続） | S7 |
| `E-ART-EMPTY-POOL-001` | ART | アーティスト特集有効だが artists.yaml が空／未生成 → 特集スキップ（throw しない・診断ログ用） | S15 |
| `E-ART-INSUFFICIENT-TRACKS-001` | ART | 再生可能曲が 3 曲未満 → 特集スキップ（throw しない・診断ログ用） | S15 |
