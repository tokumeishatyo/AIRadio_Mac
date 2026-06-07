# S1 — VOICEVOX TTS + 音声再生

## 1. 概要
DJ の声を実際に出す最初のスライス。VOICEVOX のローカル HTTP API で日本語テキストを WAV 合成し、
`AVAudioPlayer` で再生する。HTTP は `HTTPClient` 抽象越しにして TTS ロジックを単体テスト可能にする。
設定ロード基盤（Yams）を初導入し、VOICEVOX エンドポイントを `config/tts.yaml` に外部化する。

## 2. スコープ

**in**:
- 依存パッケージ **Yams** 追加（Infra）
- `HTTPClient` protocol + `URLSessionHTTPClient`（Infra）。`HTTPClientError`
- `VoicevoxTTS`（Infra, `TTSBackend` 実装）— `audio_query` → `synthesis` の 2 段呼び出し
- `AVAudioPlayerBackend`（Infra, `AudioPlayer` 実装）— WAV 再生 + 完了待ち、キャンセルで停止
- `TtsConfig` + `TtsConfigLoader`（Infra, Yams）— `config/tts.yaml` の `voicevox.endpoint` / `credit`
- `config/tts.yaml`
- エラー `TtsError`（unreachable / synthesisFailed）・`AudioError`（playbackFailed）を Core に追加
- `AIRadioApp` のデモ: tts.yaml ロード → 「こんにちは…」を VOICEVOX(ずんだもん=3) で合成 → WAV 保存 → 再生
- テスト: VoicevoxTTS（fake HTTPClient）/ TtsConfigLoader / AVAudioPlayerBackend（不正データ）
- `docs/specs/error-codes.md` 追記

**out（後続）**:
- 複数 DJ・話者マッピング（personalities.yaml）→ 後続
- ダッキング・テーマ曲（Spotify）→ S2 / S3
- LLM 台本生成 → S6

## 3. VOICEVOX 連携
- `POST {endpoint}audio_query?speaker={id}&text={text}` → クエリ JSON
- `POST {endpoint}synthesis?speaker={id}`（body=クエリ JSON, Content-Type: application/json）→ WAV
- 失敗時: 接続不可（URLError）→ `TtsError.unreachable` / その他 → `TtsError.synthesisFailed`

## 4. 受け入れ条件
- `swift build` 成功（Yams 解決含む）
- `swift test` 全グリーン（ネットワーク・音声デバイス非依存。VOICEVOX 実機は使わず fake で検証）
- 実機で `swift run AIRadioApp` がずんだもんの声を再生（聴覚確認、ユーザー）

## 5. エラーコード（追記）
| コード | 発生条件 |
|---|---|
| `E-TTS-UNREACHABLE-001` | VOICEVOX に接続できない |
| `E-TTS-SYNTHESIS-FAILED-001` | 合成 API がエラー応答 |
| `E-RTM-AUDIO-PLAYBACK-001` | 音声再生の開始に失敗 |
