# ケイラボAIラジオ Mac版 プロジェクトルール（CLAUDE.md）

> **本ファイルは「コードを書くたびに必要となる横断ルール」だけを置く。**
> 要件 (WHAT) / 設計 (HOW) / 機能別仕様の詳細は Confluence に集約し、必要時のみ参照する（§5）。
> CLAUDE.md は毎セッション必ずコンテキストを消費するため、肥大化を避ける。

本プロジェクトは Windows 版『K-LAB Radio Studio (仮)』の**精神を継承しつつ簡素化**した Mac 版。
Windows 版リポジトリのクローンは `../AIRadio-main/`（**読み取り専用の参考**、編集・コミット禁止）。

---

## 1. プロジェクト概要

PC 作業中のバックグラウンド利用を想定した、**メニューバー常駐型の自律 AI ラジオ**「ケイラボAIラジオ」。
AI DJ が気ままに喋り、Spotify の曲をかける。論理的進行管理（番組フォーマット）と LLM のカオス的生成を両立。

要件詳細は Confluence『Mac版 要件定義』、設計は『Mac版 設計』を Source of Truth とする（§5）。

---

## 2. 技術スタック（確定）

| カテゴリ | 採用 |
|---|---|
| 言語 / 並行 | Swift 6.2 / async-await + structured concurrency（Task / TaskGroup）|
| パッケージ | Swift Package Manager（Xcode プロジェクト不要）。メニューバーは executable target で `NSApplication` を `.accessory` 化 |
| UI | AppKit `NSStatusItem`（常駐）+ SwiftUI（最小ウィンドウ）|
| 設定 | YAML = Yams + `Codable`（外部依存パッケージは **Yams 1 つのみ**）|
| HTTP | `URLSession`（Gemini / Spotify Web API / News RSS / 気象庁）|
| 音声再生 | `AVFoundation`（`AVAudioPlayer`、WAV 再生 + 完了待ち）|
| Spotify 再生制御 | AppleScript（`NSAppleScript` / `osascript`）|
| LLM | Gemini 3.1 Flash Lite + Gemma 4 26B（Google API 無料枠）。`LLMBackend` 抽象で差し替え |
| TTS | VOICEVOX（ローカル HTTP）。`TTSBackend` 抽象で将来 Google AI 音声に差し替え余地 |
| テスト | **Swift Testing**（`@Test` / `#expect`）|
| ログ | `os.Logger`（機密マスク）|

---

## 3. 横断ルール（全モジュール必須）

### 3-1. 完全静寂（Idle / Stop）の絶対保証
ユーザーが停止した場合、Spotify 制御・LLM リクエスト・TTS 合成・外部リサーチ（News / 天気）を**完全休止**する。
放送全体を 1 つの `Task` で回し、停止は `Task.cancel()`。各 await 点で `CancellationError` を伝播させ、
`defer` で Spotify を必ず `pause()`（鳴らしっぱなしにしない）。

### 3-2. プレフライトチェック原則
DJ が曲紹介テキストを生成する**前**に、該当楽曲の検索・再生可否（`TrackSearcher.isPlayable`）を必ず確認する。
不可なら代替曲を選定。「紹介した曲が流れない」放送事故を論理的に排除する。

### 3-3. 機密情報の取扱
API キー / client_id / secret はソースコード・コミット対象ファイルに**絶対に書かない**。
`config/*.local.yaml`（`.gitignore` 対象、dev）または macOS Keychain（配布）経由で注入。ログ出力時はマスク。

### 3-4. YAML 設定ファイルの命名規約
- ファイル名: `kebab-case.yaml` ／ キー名: `snake_case`
- 機密値を含むファイル: `<name>.local.yaml`（`.gitignore` 対象）
- 配置: `config/` ディレクトリに集中

---

## 4. 命名規約・テスト方針

### 4-1. コード内識別子
英語（型 = UpperCamelCase / 変数・関数 = lowerCamelCase）。日本語表示文字列（DJ 名・コーナー名等）は
**YAML 設定に一元集約**し、業務ロジックに散在させない。

### 4-2. 抽象 protocol
Swift 慣習に従い `I` プレフィックスは**付けない**。PascalCase で役割名（例: `LLMBackend` / `TTSBackend` /
`AudioPlayer` / `TrackSearcher` / `SpotifyController` / `ResearchSource` / `Clock`）。
外部依存は必ず protocol 越しにアクセスし、テストで fake 差し替え可能にする。

### 4-3. エラーコード
形式 `E-<CAT3>-<DETAIL>-<NNN>`（例: `E-SPT-NO-DEVICE-001`）。Swift では enum の case に安定コード文字列を持たせる。
カテゴリ: CFG / RTM / SPT / TTS / LLM / NEWS / WX / RES / ART / JNL / PRON。台帳は `docs/specs/error-codes.md`。
放送事故ゼロ系（プレフライト・BGM 失敗）は fail-tolerant（ログ + 継続）、起動時設定不正は fail-fast。

### 4-4. テスト方針
**Swift Testing** を使用。外部依存（TTS / LLM / Spotify / Audio / Clock / Research）は protocol 越しに fake 差し替え。
Core 層は完全に単体テスト可能とする。**`swift test` グリーンを各スライスの完了条件**とする。
聴覚・視覚確認が必要な要素は実装完了報告で明示する。

---

## 5. Confluence 索引

- Site: `aaic.atlassian.net` ／ Space: **AIRadio**（id `28835843`, key `AIRadio`）

| ページ | id | 用途 |
|---|---|---|
| Mac版 要件定義 | `37519362` | 要件 (WHAT) の Source of Truth |
| Mac版 設計 | `37617666` | 設計 (HOW) のハブ |
| Mac版 仕様 | `37519389` | 機能別仕様（`docs/specs/` ミラー）のハブ + 実装進捗 |
| Mac版 CLAUDE.md | `37486597` | 本ファイルのミラー |

書き込みは `markdown` または `html` 形式。Windows 版ページ（要件定義 28934153 等）は**参照のみ・編集禁止**。

### 編集ポリシー
| 種別 | 編集先 |
|---|---|
| 横断ルール | ローカル `CLAUDE.md` → Confluence『Mac版 CLAUDE.md』ミラーへ反映 |
| 要件 | Confluence『Mac版 要件定義』のみ |
| 設計 | Confluence『Mac版 設計』のみ |
| 仕様 | `docs/specs/<feature>.md` を SoT として編集 → Confluence『Mac版 仕様』配下にミラー |
| 実装進捗 | Confluence『Mac版 仕様』配下のチェックリスト |

---

## 6. ディレクトリ構成

```
AIRadioMac/                       # Mac版プロジェクトルート（将来 git root）
├── Package.swift
├── Sources/
│   ├── AIRadioCore/              # protocol + ドメインロジック（外部依存ゼロ）
│   ├── AIRadioInfra/             # 外部実装（VOICEVOX / Gemini / Spotify / Audio / Research）
│   └── AIRadioApp/               # @main メニューバー UI + DI 配線
├── Tests/
│   ├── AIRadioCoreTests/
│   └── AIRadioInfraTests/
├── config/                       # YAML 設定（機密は *.local.yaml）
├── docs/specs/                   # 機能別仕様（SoT）
└── CLAUDE.md
```
依存方向は外側 → 内側（App → Infra → Core）。

---

## 7. 仕様駆動ワークフロー

1. `docs/specs/<feature>.md` を先に書く（仕様凍結）
2. git commit
3. Confluence『Mac版 仕様』配下に同内容 + 実装チェックリストをミラー作成
4. 実装 + テスト（`swift test` グリーン）
5. git commit
6. Confluence でチェックボックス更新

---

## 8. その他

- `../AIRadio-main/`（Windows 版クローン）は**読み取り専用の参考**。編集・コミット・push 禁止。
- `../方針.md` は git 除外（Mac 版の出発メモ）。
- 本 CLAUDE.md は Mac 版リポジトリに**コミット可**。ユーザーレベル CLAUDE.md は持ち込まない。
