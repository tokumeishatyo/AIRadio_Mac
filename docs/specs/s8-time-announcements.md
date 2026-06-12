# S8 — 時刻・日付入りアナウンス + ニュース読み上げ DJ の変更

## 1. 概要
OP・ニュースのアナウンスに現在の日付・時刻を組み込む（Windows 版 DailyContext の挨拶仕様を踏襲）。
あわせてニュースの読み上げ DJ をずんだもんから**青山龍星**に変更する。

- **OP**: 時間帯で挨拶を変える（おはようございます / こんにちは / こんばんは）＋
  「◯月◯日、午前/午後◯時になりました。ケイラボAIラジオの時間〜」
- **ニュース**: 「時刻は◯時◯分になりました。ニュースの時間です。」
  （日付なし・午前/午後なしの 12 時間表記）

## 2. スコープ

**in**:
- `TimeOfDay`（Core）: Windows 版仕様の時間帯区分をそのまま踏襲
  - Morning 05:00–11:59 / Afternoon 12:00–16:59 / Evening 17:00–04:59（深夜またぎ）
- `TimePhrases`（Core）: `Date` + 挨拶設定 → プレースホルダ値辞書を生成する純粋ロジック
- 挨拶文字列は `config/themes.yaml` の `greetings:`（morning/afternoon/evening）に外部化
  （CLAUDE.md §4-1。Windows 版 greetings.yaml と同じ形）
- `BroadcastEngine` に `Clock` を注入し、テーマアナウンス（OP/ニュース/ED）を**発話直前に**
  `TemplateExpander` で時刻展開（ニュースは Provider 原稿 → 時刻の二段展開）
- ニュース読み上げ DJ: `program.yaml` のテーマ系セグメントに任意の `dj_id` を追加
  （未指定は `anchor_dj_id`）。ニュースは `ryusei`（青山龍星）に設定
- `config/djs.yaml` に青山龍星を追加（speaker_id=13、/speakers で実在確認済み）
- 文言更新: `themes.yaml`（OP テンプレ化）/ `research.yaml`（ニュース冒頭に時刻）
- テスト: TimeOfDay 境界 / TimePhrases の各値 / エンジンの展開とニュース DJ 解決 / ローダ

**out（後続）**:
- ED への時刻組み込み（仕組みは同じ。文言要望が出たら yaml 編集のみ）
- DailyContext の本格版（暦・記念日・季節等）→ 後続スライス

## 3. プレースホルダ仕様（`TimePhrases.values(date:greetings:)`）

| キー | 値 | 例（6/12 15:07） |
|---|---|---|
| `{greeting}` | 時間帯挨拶（greetings 設定から） | こんにちは |
| `{month}` / `{day}` | 月・日（数値、ゼロ埋めなし） | 6 / 12 |
| `{ampm}` | 午前 / 午後 | 午後 |
| `{hour}` | NHK 式 12 時間（0–11、`{ampm}` と組で使う。12:xx は「午後0時」） | 3 |
| `{hour12}` | 午前/午後なしの 12 時間表記（0:xx→0、12:xx→12、それ以外 1–11） | 3 |
| `{minute}` | 分（ゼロ埋めなし） | 7 |

- カレンダーは Gregorian + `TimeZone.current`。時刻は `Clock.now`（テストでは FakeClock）。
- 未知プレースホルダは `TemplateExpander` 仕様で原文のまま残る（誤記が音声で発覚できる）。

## 4. 文言（設定変更）

```yaml
# themes.yaml（追加・変更部分）
greetings:
  morning: "おはようございます"
  afternoon: "こんにちは"
  evening: "こんばんは"
opening:
  announcement: "{greeting}。{month}月{day}日、{ampm}{hour}時になりました。ケイラボAIラジオの時間なのだ。…（以下従来文）"

# research.yaml
announcement_template: "時刻は{hour12}時{minute}分になりました。ニュースの時間です。{news} 続いて天気予報です。{weather} 以上、ニュースと天気予報でした。"

# program.yaml（news セグメント）
    - type: news
      dj_id: ryusei   # 青山龍星（未指定セグメントは anchor_dj_id）
```

## 5. 受け入れ条件
- `swift build` / `swift test` 全グリーン（時刻系は FakeClock で決定論的に検証）
- `AIRADIO_DEMO=broadcast` で、OP が「（時間帯挨拶）。◯月◯日、午前/午後◯時になりました。〜」、
  ニュースが「時刻は◯時◯分になりました。ニュースの時間です。〜」と**実時刻**で読まれる（ユーザー確認）
- ニュースの声が**青山龍星**になっている（ユーザー確認）
- エラーコードの追加なし（dj_id 未定義は既存 `E-CFG-MISSING-FIELD-001` で fail-fast）
