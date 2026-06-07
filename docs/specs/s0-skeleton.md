# S0 — SwiftPM スケルトン + Core protocol + テスト土台

## 1. 概要
Mac版の土台。3層 SwiftPM パッケージを作り、Core の protocol 抽象群・ドメイン型・エラーパターン・
純粋ユーティリティ、テスト用 fake 一式、最小 App エントリを用意して **`swift test` グリーン**を確立する。
外部依存パッケージはまだ追加しない（Yams は設定ロード着手の S1 で追加）。

## 2. スコープ

**in**:
- `Package.swift`（5 ターゲット）
  - `AIRadioCore`（library）
  - `AIRadioInfra`（library, → Core）
  - `AIRadioTestSupport`（library, → Core。fake 一式）
  - `AIRadioApp`（executable, → Core/Infra。スタブ main）
  - `AIRadioCoreTests` / `AIRadioInfraTests`（testTarget）
- `AIRadioCore`:
  - protocol: `LLMBackend` / `TTSBackend` / `AudioPlayer` / `TrackSearcher` / `SpotifyController` / `ResearchSource` / `Clock`（すべて `Sendable`）
  - DTO: `LLMRequest` / `TrackInfo` / `PlayerState` / `PlaybackState`
  - エラー: `RadioError`（code/message）+ `SpotifyError` / `ConfigError`
  - 純粋 util: `TemplateExpander`（`{key}` 置換、テンプレート展開の土台）
- `AIRadioInfra`: `SystemClock`（実 `Clock`）
- `AIRadioTestSupport`: `EchoLLM` / `InMemoryTTS` / `FakeClock` / `SpyAudioPlayer` / `FakeTrackSearcher` / `FakeSpotifyController` / `FakeResearchSource`
- テスト: TemplateExpander / Errors / fakes / SystemClock
- `docs/specs/error-codes.md` 台帳の起票
- `.gitignore`

**out（後続）**:
- YAML 設定ロード（Yams）→ S1
- 実エンジン（VOICEVOX / Gemini / Spotify）→ S1+
- 統一テーマエンジン → S3
- メニューバー UI → S7

## 3. 受け入れ条件
- `swift build` 成功
- `swift test` 全グリーン
- 外部依存パッケージ **0**（標準ライブラリのみ）
- 依存方向 App → Infra → Core を厳守（Core は何も import しない）

## 4. エラーコード（本スライスで起票）
| コード | 発生条件 |
|---|---|
| `E-SPT-NO-DEVICE-001` | 再生可能な Spotify がない |
| `E-SPT-API-FAILED-001` | Spotify 操作の一般失敗 |
| `E-CFG-MISSING-FIELD-001` | 設定の必須フィールド欠落 |

## 5. テスト戦略
- `TemplateExpander`: 既知キー置換 / 未知キーは原文保持。
- `Errors`: 各 case の `code` 文字列が安定キーと一致。
- fakes: `EchoLLM` がプロンプトをエコー / `InMemoryTTS` が非空データ / `FakeClock.sleep` 即時 /
  `FakeSpotifyController` が呼び出し順を記録 / `FakeTrackSearcher` がクエリ記録と結果返却。
- `SystemClock`: `sleep(0)` が完了し、`now` が単調。
