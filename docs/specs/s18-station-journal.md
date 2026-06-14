# S18 — ステーション・ジャーナル（週次リセットの長期記憶）

> 仕様駆動ワークフロー（CLAUDE.md §7）の SoT。**実装前にユーザーレビューを受ける**（本スライスは設計判断が多いので §12 を要確認）。
> 要件定義 §8「ステーション・ジャーナル（長期記憶）」の採用分。参照: `s17-daily-context.md`（dateContext 注入の前例）, `../CLAUDE.md`。

## 1. 概要

番組に**地続き感**を持たせる長期記憶。**番組終了時に「その回のハイライト」を LLM で短く要約してローカルに永続化**し、
**次回起動時にプロンプトへ注入**して「前回はこんな話をした」と振り返れるようにする。肥大を防ぐため **週次でリセット**
（日曜まで貯め、週が変われば＝月曜の最初の放送で前週分を破棄）＋ **ファイルを人為削除すれば即クリア**の二段構え。

## 2. データモデル（Core）

- `struct JournalEntry { date: String("YYYY-MM-DD"); highlight: String }`（1 放送 = 1 エントリ）。
- `struct StationJournal { weekKey: String; entries: [JournalEntry] }`
  - `weekKey` = **ISO 週（月曜始まり）の "YYYY-Www"**（例 "2026-W24"）。週の同一判定に使う。
  - `func entriesForCurrentWeek(now:timeZone:) -> [JournalEntry]`: `weekKey` が現在の週と一致すれば `entries`、違えば空（＝週替わりで忘れる）。
  - `func appended(entry:now:timeZone:) -> StationJournal`: 週が変わっていれば entries を空にしてから追記（weekKey も更新）。**週次リセットはここで判定**。
- 上限: 週内最大 7 エントリ（1 日 1 放送想定）。超えたら古いものから落とす（リングバッファ）。

## 3. ハイライトの収集（番組終了時）

- `BroadcastEngine` が放送中に分かる事実を **`BroadcastDigest`** に集める（run 内で保持）。**収集対象は日付・曜日・ゲスト名・特集アーティスト名のみ**（確定 A）:
  - 日付・曜日（`DailyCalendar` 連携）、**ゲスト名**（`selectedGuest`、BroadcastEngine.swift:109）、**特集アーティスト名**（`selectedArtist`、:127）。
  - **トークの「テーマ」は含めない**（確定 A）。テーマは `CornerEngine` 側で選ばれるため収集に追加配線が要るが、地続き感はゲスト・特集で十分とし、簡素を優先する。
- `broadcastFinished`（BroadcastEngine.swift:242）の直前に、集めた digest を **LLM で 1〜2 文に要約**（`JournalSummarizer`）→ `JournalEntry` を作り、
  `StationJournal.appended(...)` で追記して **保存**。LLM 失敗時は決定論テンプレ（「{日付}、ゲスト{guest}・{artist}特集をお届けしました」）にフォールバック。

## 4. 永続化（Infra）

- 抽象 `protocol JournalStore { func load() throws -> StationJournal; func save(_ journal: StationJournal) throws }`（Core）。テストで fake 差し替え。
- 実装 `YamlJournalStore`（Infra）: **`config/journal.local.yaml`**（`.gitignore` 対象。機密ではないがユーザーデータ＝出荷時は無し）。
  ファイルが無ければ空ジャーナル。壊れていたら**握り潰して空**（fail-tolerant。長期記憶は番組事故ゼロ系＝壊れても放送は続ける）。
- **人為削除で即クリア**: ファイルを消せば次回は空から（二段構えの片方）。

## 5. 週次リセット（二段構えのもう片方）

- 放送開始時に `load()` → `entriesForCurrentWeek(now:)` を使う。`weekKey` が現在週と違えば**空が返る**（前週分は注入しない）。
- 次の保存（`appended`）で weekKey が現在週に更新され、entries は新週ぶんだけになる（＝月曜の最初の放送で前週が消える）。

## 6. 注入（次回放送のプロンプト）

- 放送開始時に当週のハイライトを連結した **`journalContext` 文字列**を作る（例「先日はゲストにあんこもんさんを迎え、米津玄師さんを特集しました。」）。
- **注入先＝冒頭コーナーのみ**（確定 B）: `greeting` 分岐に「前回までの振り返りに**軽く一言**触れる（長々と振り返らない）」を足す。
  毎コーナーに入れると冗長・反復になるため冒頭に絞る。`DialogueScriptGenerator.makeRequest` に `journalContext: String = ""` を足す（dateContext と同型の注入経路）。
- 当週エントリが無い（週初・初回・ファイル無し）ときは注入なし（従来どおり）。

## 7. 完全静寂・事故ゼロとの整合

- **保存は正常終了時のみ**（`broadcastFinished` 経路）。**停止（Ctrl-C / メニュー停止）・キャンセルでは保存しない**（中断した回はハイライトにしない＝完全静寂中に I/O を増やさない。§3-1 と整合）。
  - 【設計判断 D】「ED で正常に締めた回だけ記録」でよいか（停止された回は記録しない）。
- 長期記憶は**事故ゼロ系（fail-tolerant）**: 要約 LLM 失敗・ファイル破損・保存失敗のいずれも**放送は止めない**（ログのみ）。エラーコードは新カテゴリ `JNL`（`E-JNL-*`、throw しない）。

## 8. 配線

- `BroadcastWiring` が `YamlJournalStore(path: "config/journal.local.yaml")` と `JournalSummarizer(llm:)` を作り、`BroadcastEngine` に注入。
- `BroadcastEngine.run` 冒頭で `load()`→当週ハイライト→`journalContext` をコーナー準備に渡す。終了時に digest を要約→`appended`→`save`。

## 9. テスト（`swift test` グリーンが完了条件）

- `StationJournal`: 当週一致で entries を返す／週違いで空／`appended` が週替わりでリセット／7 件上限のリングバッファ。週キーは固定日付・TZ 固定で検証（月曜境界）。
- `JournalStore`（fake）: load/save 往復、ファイル無し＝空、壊れ＝空（fail-tolerant）。
- `JournalSummarizer`: digest → LLM 要約、LLM 失敗で決定論フォールバック。
- `BroadcastEngine`: 正常終了で要約・保存が呼ばれる／停止では呼ばれない／当週ハイライトが冒頭コーナーの準備に渡る（注入）。
- `DialogueScriptGenerator`: `journalContext` 非空で冒頭プロンプトに振り返りセクションが入る／空なら入らない／途中コーナーには入らない。

## 10. 受け入れ基準（ライブ確認）

1. 1 回放送 → 終了後に `config/journal.local.yaml` が作られ、その回のハイライト要約が入る。
2. 同じ週にもう 1 回放送 → 冒頭で**前回の振り返り**（ゲスト・特集など）に軽く触れる。
3. ファイルを削除 → 次回は振り返りなし（クリア）。
4. （週境界）weekKey をまたぐと前週分が消える（テストで担保。実放送は週替わりで確認できれば）。
5. 停止（Ctrl-C）で終えた回は記録されない。既存進行・完全静寂に影響なし。

## 11. スコープ外

- 会話の逐語ログ保存（要約のみ＝肥大回避）。複数番組・複数局のジャーナル。クラウド同期。
- テーマのジャーナル化（§3 設計判断 A で「含めない」なら）。

## 12. 設計判断（確定・2026-06-14 ユーザー承認）

- **A. ハイライトの中身**: **日付・ゲスト・特集のみ**（テーマは含めない）。振り返りは**軽く一言**（長々触れない）。
- **B. 注入先**: **冒頭コーナーのみ**。
- **C. 週境界**: **ISO 週（月曜始まり）**で「日曜まで貯め・月曜の最初の放送で前週クリア」。
- **D. 保存タイミング**: **ED で正常終了した回のみ記録**（停止/キャンセルは記録しない）。
- **E. 保存先**: **`config/journal.local.yaml`**（gitignore・人為削除で即クリア）。
