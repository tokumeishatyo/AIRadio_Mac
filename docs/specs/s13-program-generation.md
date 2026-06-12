# S13 — コーナー数駆動の番組生成 + ローリング先行準備 + ED で終了 + 番組の長さ UI

## 1. 概要

番組を固定セグメント列から**コーナー数 N で決定論的に生成する方式**へ進化させ、長時間・エンドレス
放送を可能にする。準備（LLM + TTS）は全部先行から**ローリング方式**（再生中に次の 1〜2 セグメント
だけ準備）へ。放送中に**「ED で終了」**で優雅に締められる。

## 2. 番組生成規則（ProgramPlan、決定論的）

- N = **トークコーナー（free_talk）の本数**。お便り / ニュース / OP / 冒頭曲 / ED は数えない。
- 構成: `opening → song（冒頭曲）→ 本編 → ending`
  - 本編: トーク 2 本ごとに「お便り → ニュース」を自動挿入
    （= `talk, talk, letter, news` の繰り返し）
  - **端数処理**: N が奇数のとき、最後の 1 本のトークの後はお便り・ニュースを挟まず ED へ
  - **エンドレス**: `talk, talk, letter, news` を無限に繰り返す。**ED セグメントなし**
    （終了は「放送を停止」= 即静寂、または「ED で終了」ボタン）
- 例: N=4 → `OP, song, t1, t2, letter, news, t3, t4, letter, news, ED`（11 セグメント）
  / N=3 → `OP, song, t1, t2, letter, news, t3, ED`（8 セグメント）
- Core `ProgramLength`: `.corners(Int)` / `.endless`
- Core `ProgramPlan`: `segment(at: Int) -> ProgramSegment?`（有限は ED の次で nil、エンドレスは常に非 nil）
  + `totalSegmentCount: Int?`（エンドレスは nil、UI の「n/全体」表示用）
- Core `ProgramBlueprint`（program.yaml v2 の中身）: title / anchorDjId / defaultLength /
  openingCritical / song: SongSegmentSpec / talkCornerId / letterCornerId / newsDjId

## 3. ローリング先行準備（BroadcastEngine の進化）

- 全先行準備（S10）をやめ、**実行中セグメントの先 2 つまで**の準備 Task を保持する
  （窓 W=2。セグメント i の実行開始時に i+1, i+2 の準備を起動、i の準備は消費後に破棄）。
- 準備内容は従来どおり: talk/letter = `CornerRunning.prepare`（台本 + 全行 TTS）/
  news = 原稿生成 / song = 選曲。opening / ending は準備なし。
- **news は出現のたびに生成**（長時間放送でニュースが更新される。S11 の「1 回だけ生成」から変更）。
- `{first_song}` は従来どおり: OP 実行前に冒頭曲（index 1）の選曲完了を待つ
  （放送開始前の無音は許容、放送中の無音ゼロの原則は不変）。
- 停止（Task.cancel）時は保持中の準備 Task をすべてキャンセル（S10 と同じ機構）。

## 4. ED で終了（graceful ending）

- Core `BroadcastControl`（Sendable、UI スレッドから安全に操作可）: `requestEnding()` /
  `isEndingRequested`。
- エンジンは**各セグメントの完了時**に判定:
  1. 次のセグメントが **トーク（free_talk）かつ準備完了済み**なら、それを流してから ED
  2. それ以外（お便り / ニュース / 未準備のトーク / song）は**すべて飛ばして即 ED**
  3. 残りの準備 Task はすべてキャンセル（「窓の外を捨てる」）
- エンドレスでも有効（ED ボタンが唯一の「優雅な」終わり方）。有限で ED 実行後は通常終了と同じ。
- `BroadcastEvent.endingRequested` を追加（コンソールに「ED で終了を受け付けました」）。

## 5. UI（メニューバー）

- **「ED で終了」**: 放送中のみ有効。押すと §4 の動作。
- **サブメニュー「番組の長さ」**: `トーク 10 本 / 20 本 / 30 本 / エンドレス`（現在値にチェック）。
  - 選択は **UserDefaults**（key `programLength`、値 "10"/"20"/"30"/"endless"）に保存し再起動後も保持
  - 既定値は program.yaml の `default_length`
  - 変更は**次の放送開始から**反映（放送中の変更は次回分）
- 放送中の状態表示: `放送中: talk (5/23)`。エンドレスは分母を `∞` にする。

## 6. config（program.yaml v2、セグメント列 → 部品宣言）

```yaml
program:
  title: "ケイラボAIラジオ"
  anchor_dj_id: zundamon
  default_length: 10          # 10 / 20 / 30 / endless
  opening:
    critical: true            # OP 失敗は放送中止（既定 true、Windows 踏襲）
  song:                       # 冒頭曲（従来の song セグメントと同じキー）
    song_prompt_hint: "..."
    fallback_track_uri: "..."
    volume: 100
    play_seconds: 0
  talk:
    corner_id: free_talk
  letter:
    corner_id: letter
  news:
    dj_id: ryusei
```

- 旧形式（`segments:` 列挙）は**廃止**（設定駆動の精神は維持: 部品の差し替え・既定長は YAML で変更可）。
- `default_length` 不正値は fail-fast（`E-CFG-MISSING-FIELD-001` 流用、エラーコード追加なし）。

## 7. テスト

- ProgramPlan: N=1/2/3/4/10 の全列挙（端数・ED 位置）/ エンドレスの先頭 12 個 + totalSegmentCount=nil
- ローリング: セグメント k 開始時点で起動済み準備が k+2 以下（記録 fake で呼び出し順を検証）/
  news が出現回数ぶん生成される / 停止で保持中の準備がキャンセル
- ED: ①次トーク準備済み → 流して ED ②次がお便り/ニュース → 即 ED ③次トーク未準備 → 即 ED /
  エンドレスでも ED で終了する
- ローダ v2: 正常 / default_length の各値 / 不正値 fail-fast / 必須欠落
- `{first_song}`・critical OP・キャンセル静寂の既存保証はテスト維持

## 8. 受け入れ条件

- `swift build` / `swift test` 全グリーン
- 長さ 10 で放送: トーク 2 本ごとにお便り → ニュースが入り、（途中で ED ボタンを押した場合）
  §4 の動作で優雅に終わる（ユーザー確認）
- エンドレスで放送が続き、「放送を停止」で即静寂（ユーザー確認）
- メニューの「番組の長さ」変更が次回放送に反映され、アプリ再起動後も保持される（ユーザー確認)
- エラーコード追加なし
