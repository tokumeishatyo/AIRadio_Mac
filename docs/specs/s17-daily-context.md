# S17 — DailyContext 拡張（曜日名・記念日の軽重）

> 仕様駆動ワークフロー（CLAUDE.md §7）の SoT。実装前にユーザーレビューを受ける。
> 要件定義 §8「DailyContext（暦）」の採用分。参照: `s12-themed-talk-letters.md`（季節コンテキスト）, `../CLAUDE.md`。

## 1. 概要

S12 で入れた**季節・日付コンテキスト**（`SeasonPhrases.dateContext`）を拡張し、**曜日名**と**記念日（重要度つき）**を
台本生成プロンプトに注入する。記念日は **`significance`（重要度）で扱いを変える**:
- **`high`（祝日級）**: その日を**番組全体に波及**させる（各コーナーが意識して織り込む。例「今日はこどもの日、こどもの日にちなんで…」）。
- **`low`（軽い暦）**: **軽く触れる程度**にとどめ、深入りしない。

これにより会話が暦に沿って自然になり、祝日には番組全体が彩られる。**S16「DJの今日の気分」も同じ `dateContext` を材料にするため、自動的に厚みが増す**（追加実装不要）。

## 2. 現状

- `SeasonPhrases.dateContext(date:timeZone:)` が `"今日は{月}月{日}日、{季節}です。"` を生成（SeasonPhrases.swift:25-32）。月→季節表は同 :7-22。
- 生成箇所は2つ: `CornerEngine.prepare`（CornerEngine.swift:106）と `ArtistFeatureEngine.prepare`（ArtistFeature.swift:204）。
- 消費は `DialogueScriptGenerator`（`# 今日の日付と季節` セクション）/ `ListenerLetter` / `makeArtistFeatureRequest`。**文字列を受け取るだけ**なので消費側は無改変で拡張できる。
- **news（`NewsScriptGenerator`）は dateContext を受けない**（「時刻や日付の定型句は書かない」設計、NewsScriptGenerator.swift:18）。本スライスの対象外（§7）。

## 3. 出力例（拡張後）

| 状況 | 注入される文字列 |
|---|---|
| 記念日なし | 「今日は6月14日（土曜日）、梅雨の時期です。」 |
| `high`（祝日級） | 「今日は5月5日（月曜日）、初夏、新緑の季節です。今日は『こどもの日』。番組を通して、こどもの日にちなんだ話題を意識して織り込んでください。」 |
| `low`（軽い暦） | 「今日は7月7日（月曜日）、盛夏です。今日は『七夕』。話の流れで軽く触れる程度にとどめてください。」 |

`high` の指示文は**毎コーナーのプロンプトに入る**ので、結果として番組の各コーナーがその日を意識する＝波及。テーマを置換するのではなく
「**意識して織り込む**」表現にして、コーナーのテーマと自然にブレンドさせる。

## 4. 設計

### 4-1. 新 Core 型
- `enum AnniversarySignificance: String { case high, low }`（`high`=祝日級・番組全体に波及／`low`=軽く触れる程度）。
- `struct Anniversary { month: Int; day: Int; name: String; significance: AnniversarySignificance }`。
- `struct DailyCalendar { weekdayNames: [String]; anniversaries: [Anniversary] }`
  - `weekdayNames` は7要素（index = `Calendar` の weekday 1=日曜 … 7=土曜）。
  - `func context(date:timeZone:) -> String`: 「{月}月{日}日（{曜日}）、{季節}です。」＋（その日の記念日があれば）重要度に応じた一文。季節は既存 `SeasonPhrases.phrase(forMonth:)` を流用。
  - `static let standard`（`weekdayNames` = 標準の日本語7名、`anniversaries` = 空）。config 省略時のフォールバック（`WeeklyCast.standard` と同じ流儀）。

### 4-2. 新 Infra ローダ
- `DailyCalendarLoader`（`config/calendar.yaml` → `DailyCalendar`）。`weekday_names`（省略時 standard）と `anniversaries`（`date: "MM-DD"` / `name` / `significance`）を読む。空・未指定は standard／空配列、`significance` 不正値・壊れ yaml は throw（CFG）。

### 4-3. config（新規 `config/calendar.yaml`）
```yaml
# 曜日名（index = Calendar の weekday。1=日曜 … 7=土曜）。省略時は標準日本語。
weekday_names: ["日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日"]
# 記念日（MM-DD → 名前 + significance）。high=祝日級は番組全体に波及 / low=軽く触れる程度。
anniversaries:
  - { date: "01-01", name: "元日",       significance: high }
  - { date: "05-05", name: "こどもの日", significance: high }
  - { date: "07-07", name: "七夕",       significance: low }
  - { date: "11-22", name: "いい夫婦の日", significance: low }
```
> **命名メモ（レビュー要）**: 要件定義 §8 では `config/anniversaries.yaml` と書いたが、曜日名も持たせるため `config/calendar.yaml`（暦設定の集約）に改名する案。OK なら要件定義の表記も合わせて更新。実装時に主要祝日＋いくつかの記念日で作り始める（網羅は後追いで追記可）。

### 4-4. 注入（配線）
- `CornerEngine` と `ArtistFeatureEngine` に `DailyCalendar` を注入し、`SeasonPhrases.dateContext(...)` 呼び出しを
  `dailyCalendar.context(date: clock.now, timeZone: timeZone)` に置換。既定引数は `.standard`（既存テストは曜日付きに期待値更新）。
- `BroadcastWiring` が `config/calendar.yaml` をロードして両エンジンへ注入。
- 消費側（`DialogueScriptGenerator` / `ListenerLetter`）は文字列を受けるだけなので**無改変**。

## 5. 重要度（significance）の扱い

- その日に一致する記念日が複数あるとき: **`high` を優先**（high が1件でもあれば high 文、なければ low 文）。代表1件のみ言及（複数列挙は冗長）。一致は `month`/`day` で判定。
- 一致なし: 従来どおり 曜日＋季節のみ。
- `high` の波及はテーマ置換ではなく「意識して織り込む」誘導（コーナーのテーマと共存）。

## 6. テスト（`swift test` グリーンが完了条件）

- `DailyCalendar.context`: (a) 記念日なし＝曜日＋季節のみ (b) `high`＝「番組を通して…織り込んでください」文が付く (c) `low`＝「軽く触れる程度」文が付く (d) 同日複数は `high` 優先 (e) 曜日名が `weekdayNames` から正しく引かれる（固定日付・TZ 固定で検証）。
- `DailyCalendarLoader`: 正常／`weekday_names` 省略は standard／`anniversaries` 空／`significance` 不正は throw／壊れ yaml は throw。
- `CornerEngine` / `ArtistFeatureEngine`: 注入した `DailyCalendar` の context が生成プロンプトに入る（記念日日付で `high` 文が台本プロンプトに現れる）。
- 既存の dateContext 期待値（曜日なし）を曜日入りに更新。

## 7. スコープ外

- **news への記念日注入**（news は dateContext を受けない設計。`high` 波及に news も含めたいかは別途相談）。
- 季節表（month→phrase）の config 化（既存ハードコード。将来 `prompts.yaml` / 可搬性作業でまとめて）。
- 記念日の網羅的リスト整備（最小から始め、運用で追記）。

## 8. 受け入れ基準（ライブ確認）

1. 通常日: コーナーの会話に**曜日・季節が自然に**出る（季節ズレなし）。
2. 祝日（`calendar.yaml` に当日を `high` で登録して確認）: **複数コーナーでその日にちなんだ話題**が織り込まれる。
3. 軽い記念日（`low` 登録）: 触れても**軽く、深入りしない**。
4. 既存の進行（曲・ニュース・お便り・ゲスト・特集・完全静寂・S16 の今日の気分/リード文）に影響なし。
