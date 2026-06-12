# S7 — 番組進行エンジン（BroadcastEngine + 番組フォーマット設定）

## 1. 概要
これまで単発デモだった各セグメント（統一テーマ演出 / 会話コーナー / ニュース天気）を、
**設定駆動の番組フォーマットに従って 1 本の放送として順次実行する** `BroadcastEngine` を実装する。

- 番組構成は `config/program.yaml` で宣言（順序の入替え・追加が設定のみで可能）。
- 標準番組構成 13 項目（要件定義）へは部品が揃い次第セグメント追加で近づける。
  本スライスは現有部品で **OP → トークコーナー → ニュース天気 → ED** を通す。
- 放送全体を 1 つの `Task` で回し、停止は `Task.cancel()`（CLAUDE.md §3-1）。
- **コーナースキップで放送継続**: セグメント失敗は記録して次へ進む（fail-tolerant）。
  キャンセルだけは即時伝播し、どの経路でも最後は必ず `pause()`（完全静寂）。

## 2. スコープ

**in**:
- `ProgramSegment` / `SegmentKind`（Core DTO）: `opening` / `talk` / `news` / `ending`
- `BroadcastEngine`（Core）: セグメント列を順次実行。進行イベント通知（`BroadcastEvent`）。
  - `opening` / `ending`: `ThemeSequencing.run`（themes.yaml の固定 announcement）
  - `news`: ニュース原稿を取得（fail-tolerant な `AnnouncementProviding`）→ news テーマで読み上げ
  - `talk`: `CornerRunning.run`（S6 の会話コーナー。`corner_id` でテンプレ参照）
- 抽象の追加（Core protocol、テスト容易性のため）:
  - `CornerRunning`（`CornerEngine` が準拠）
  - `AnnouncementProviding`（`NewsWeatherProvider` が準拠。既存 `announcement()` を protocol 化）
- `ProgramConfig` + `ProgramConfigLoader` + `config/program.yaml`
- App デモ: `AIRADIO_DEMO=broadcast`（番組 1 周を実行）。Ctrl-C（SIGINT）で `Task.cancel()` →
  完全静寂を確認できるようにする
- テスト: 進行順序 / セグメント失敗時のスキップ継続 / キャンセル即時停止 + pause /
  ニュース原稿の組み込み / ProgramConfigLoader

**out（後続）**:
- 未実装コーナー（冒頭曲・DJ の気分・お便り・アーティスト特集・ゲスト・最後の曲）→ 部品ができ次第
  `SegmentKind` を追加
- 番組の連続ループ・スケジュール実行、メニューバー UI からの開始/停止 → S8 以降（UI スライス）
- ステーション・ジャーナル / DailyContext → 後続

## 3. 番組フォーマット設定（`config/program.yaml`）

```yaml
program:
  title: "ケイラボAIラジオ"
  # opening / news / ending のテーマ読み上げを担当する DJ（djs.yaml の id）
  anchor_dj_id: zundamon
  segments:
    - type: opening
    - type: talk
      corner_id: free_talk     # corners.yaml の id を参照
    - type: news
    - type: ending
```

- `segments` は上から順に実行。`talk` は `corner_id` 必須（欠落・未定義 id は fail-fast）。
- `critical: true`（既定 false）のセグメントは失敗時にスキップせず**放送中止**（Windows 版踏襲）。
  既定の番組では OP に設定（OP が失敗する状況では後続も成立しないため）。
- `opening` / `news` / `ending` の演出・文言は既存 `config/themes.yaml` を使う（本スライスでは変更しない）。
- `anchor_dj_id` は `djs.yaml` に存在しなければ fail-fast。

## 4. BroadcastEngine の進行規則

1. セグメントを宣言順に実行する。セグメント間に追加の無音処理は挟まない
   （各セグメントが自身の演出で開始・終了する）。
2. **fail-tolerant**: セグメントが `CancellationError` 以外で失敗したら
   `BroadcastEvent.segmentFailed(index:kind:code:detail:)` を通知し、**次のセグメントへ進む**。
   （S6 までの「コーナー中断」がここで「スキップして放送継続」になる。）
   ただし `critical: true` のセグメントは失敗時に放送中止（`E-RTM-SEGMENT-FAILED-001` を throw）。
3. **キャンセル**: `CancellationError` は即時伝播。後続セグメントは実行しない。
   Infra 層がキャンセルをドメインエラーにラップして投げた場合（取消された URLSession 等）も、
   `Task.isCancelled` を確認してスキップと誤判定しない。
4. **完全静寂**: 正常終了・失敗・キャンセルのいずれでも、エンジンの最後で必ず `pause()`。
   （各セグメントも自前で pause するが、エンジンでも重ねて保証する。）
   後始末の pause は**キャンセルを継承しない Task** で送る（`pauseIgnoringCancellation()`）。
   キャンセル済み Task 内の URLSession はリクエストを送らずに取り消すため、そのまま呼ぶと
   pause が Spotify に届かず鳴りっぱなしになる。
5. イベント: `segmentStarted(index:kind:)` / `segmentFinished(index:kind:)` /
   `segmentFailed(index:kind:code:detail:)` / `broadcastFinished`。

## 5. エラーコード（追記）
| コード | 発生条件 | 扱い |
|---|---|---|
| `E-RTM-SEGMENT-FAILED-001` | セグメントが実行時エラーで中断（スキップして継続） | fail-tolerant（ログ + 継続） |

（設定不正は既存 `E-CFG-MISSING-FIELD-001` で fail-fast。）

## 6. 受け入れ条件
- `swift build` / `swift test` 全グリーン（fake 注入、ネットワーク非依存）
- 実機 `AIRADIO_DEMO=broadcast swift run AIRadioApp` で、
  **OP（テーマ演出）→ フリートーク（会話 + 一曲）→ ニュース天気（実データ + テーマ演出）→ ED** が
  1 本の放送として通しで流れる（ユーザー確認）
- 放送中に Ctrl-C すると速やかに停止し、**完全に静寂**になる（ユーザー確認）
- テストで「中間セグメントの失敗 → スキップして最後まで進行 + pause」が検証されている
