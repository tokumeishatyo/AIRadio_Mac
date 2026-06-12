# S9 — メニューバー常駐 UI（放送の開始 / 停止）

## 1. 概要
デモ CLI だった本体を、**メニューバー常駐アプリ**（要件の本来の形）にする。
`NSStatusItem` のメニューから放送（S7 の `BroadcastEngine` による番組 1 周）を開始・停止できる。

- `swift run AIRadioApp`（`AIRADIO_DEMO` なし）→ メニューバーに常駐（Dock に出さない `.accessory`）。
- 既存の CLI デモ（tts / spotify / theme / corner / broadcast 等）は `AIRADIO_DEMO` 指定時のみ。
  既定が tts デモからメニューバー起動に変わる。

## 2. スコープ

**in**:
- `BroadcastSession`（Core, actor）: 放送タスクのライフサイクル管理
  - `start(_:)`: 放送クロージャを 1 つの `Task` で開始（多重開始は拒否 = false を返す）
  - `stop()`: `Task.cancel()`（→ S7 の機構で即停止 + 完全静寂）
  - 状態: `idle` / `broadcasting`。放送が正常終了・失敗した場合も `idle` へ戻る
  - 状態変化コールバック（UI 更新用）
- App（AppKit）: `NSApplication` を `.accessory` 化 + `NSStatusItem`（📻）+ `NSMenu`
  - メニュー構成: 状態表示行（無効項目）/ 「放送を開始」⇄「放送を停止」/ 区切り / 「終了」
  - 放送中は `BroadcastEvent` で状態行を更新（例: 「放送中: ニュース (3/4)」）
  - 開始時の設定読み込み・配線は `AIRADIO_DEMO=broadcast` と同一（fail-fast エラーは NSAlert 表示）
  - 「終了」と Cmd-Q: 放送中なら `stop()`（cancel → pause）してから終了（ベストエフォート）
- テスト: `BroadcastSession`（開始 / 多重開始拒否 / 停止 = キャンセル / 正常終了で idle / 状態通知順序）

**out（後続）**:
- 署名済み `.app` バンドル化・配布（Keychain プロンプト恒久解消はここ）→ 後続
- 番組の連続ループ / 番組選択 UI / 設定ウィンドウ（SwiftUI）→ 後続
- スリープ抑止・ログイン項目 → 後続

## 3. 振る舞い

| 操作 | 動作 |
|---|---|
| 起動 | メニューバーに 📻 常駐。Dock・メインウィンドウなし。状態 = 停止中 |
| 放送を開始 | 設定読込（fail-fast は NSAlert）→ `BroadcastEngine.run` を 1 Task で開始。状態 = 放送中 + セグメント表示 |
| 放送を停止 | `Task.cancel()` → 数秒以内に完全静寂（S7 保証）。状態 = 停止中 |
| 番組が最後まで到達 | 自動的に状態 = 停止中（再度開始可能） |
| セグメント失敗 | スキップ（critical は中止）。状態行に直近のエラーコードを併記 |
| 終了 / Cmd-Q | 放送中なら stop → アプリ終了。鳴らしっぱなしにしない |

## 4. 受け入れ条件
- `swift build` / `swift test` 全グリーン（`BroadcastSession` は fake で決定論的に検証）
- `swift run AIRadioApp` でメニューバーに常駐し、**メニューから 開始 → 番組が流れる → 停止 → 即静寂 →
  再度開始できる**（ユーザー確認）
- 放送中に「終了」してもアプリが終了し、音楽が止まる（ユーザー確認）
- エラーコード追加なし（既存の fail-fast / fail-tolerant 機構をそのまま使う）
