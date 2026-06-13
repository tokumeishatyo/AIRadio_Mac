# S15 — アーティスト特集（1 放送 1 回、ゲストコーナーの直後に固定）

> 仕様駆動ワークフロー（CLAUDE.md §7）の SoT。実装前にユーザーレビューを受ける。
> 設計判断はユーザー確定（2026-06-13）。配置・構成・選定方針は §17 の確定事項に従う。
> 本仕様は S14（ゲストコーナー）の作法を踏襲する。参照: `s14-guest-corner.md`、`error-codes.md`、`../CLAUDE.md` §3。
> ※ file:line 表記はコード地図に基づく指標。実装時に現物で再確認する。

## 1. 概要

1 放送に 1 回だけ、**ゲストコーナーの直後**に「アーティスト特集」を挿入する。`config/artists.yaml`（新規）の
アーティスト一覧から**実行時にランダムで 1 組**を選び、その日のメイン／サブ DJ（S13.5）が、その**アーティストの
最大 7 曲**を「導入 → 3 曲紹介 → 3 曲連続 → 感想 → 3 曲紹介 → 3 曲連続 → 感想（短め）→ 1 曲紹介 → 1 曲 → 締め」の
固定フローでお届けする特別ブロック。番組は **最初のニュース → ゲストコーナー → アーティスト特集** という特別ブロックを
持つ（ゲストもアーティスト特集も 1 放送 1 回）。

ゲストコーナー（S14）が「1 コーナー＝1 talk セグメント＝1 曲」だったのに対し、アーティスト特集は
**1 ブロックの中に複数の発話パートと最大 7 曲が交互に並ぶ**点が構造的に新しい。よって S14 の `guest`（`.talk` で表現）
のように既存 `CornerEngine`／`PreparedCorner`（単曲モデル）へは乗らず、**マルチ曲対応の専用準備物・専用ランナー・専用
SegmentKind**を新設する（§10）。配置の決定論性・fail-fast・乱数注入・完全静寂・config ローダ同形・gen デモは S14 踏襲。

**曲の取得**は LLM に曲名を挙げさせるのではなく、**Spotify の「アーティスト上位曲（top-tracks）」API**で確定する（§5）。
これにより実在の正確な曲名・URI が得られ、「紹介した曲が流れる」事故ゼロ（CLAUDE.md §3-2）と、紹介台本の曲名一致を両立する。

`config/artists.yaml` は**出荷時は空**で、**メニューバーの「アーティスト一覧を生成」ボタン**（放送停止時のみ有効）で LLM に
アーティストを選ばせて**上書き**する（§9）。**ジャンルと件数は `config/artist-gen.yaml`（テキスト編集）で指定**（既定: 邦楽中心・
100 名。洋楽・クラシック等に変更可、ハードコードしない）。ボタンを一度も押すまでは特集は出ない（プールが空なら特集をスキップ）。

## 2. 用語

- **アーティスト特集（artist feature）**: 本仕様で追加する特別ブロック。1 組のアーティストの最大 7 曲を構成して流す。
- **特集アーティスト（featured artist）**: `artists.yaml` から実行時にランダム選定される 1 組（`ArtistProfile`）。
- **7 曲＝3+3+1**: 前半グループ 3 曲・中盤グループ 3 曲・ラストグループ 1 曲の最大 3 グループ。
- **発話パート（feature part）**: ブロック内の各発話単位（導入 / グループ紹介 / 感想 / 締め）。曲はパートではない。
- **プレフライト**: 流す曲の再生可否確認（CLAUDE.md §3-2）。本仕様では top-tracks 取得後に確定し、台本生成より前に完了する。
- **縮約**: 再生可能曲が 7 曲に満たないときの構成短縮（§6）。
- **K**: プレフライト後に確定した、実際に流せる曲数（0〜7）。

## 3. 配置（`ProgramPlan` が生成、ゲスト直後・固定位置・1 回）

S14 の「最初の news 直後にゲスト talk を 1 つ挿入」のすぐ後ろに、アーティスト特集セグメントを 1 つ挿入する。
S14 と同じく**位置は決定論的に固定**（ランダム枠選択はしない）。

### 3-1. 新しい SegmentKind

- `SegmentKind`（`Program.swift:4-10`、コメント「case を追加する（お便り・特集等）」）に **`case artistFeature`** を追加する。
  - ゲストは `.talk`（cornerId＝guestCornerId）で表現したが、アーティスト特集は**曲の本数・進行が talk と別物**なので
    独立 case とする（この非対称は意図的。レビュー誤認防止のため明記）。
  - **波及監査（必須）**: `SegmentKind` を網羅 switch している箇所（`default` なし）に case を足すとコンパイルエラーになる。
    実装時に `grep -rn "switch .*\.kind\|case .opening\|case .talk" Sources/` で全数列挙し対応する。
    最低限 `BroadcastEngine.perform`（`:266-322`）/ `startPreparation`（`:334-362`）/ `cornerContext`（`:385-408`）の 3 箇所。
    `SegmentKind` が `CaseIterable` であることにも留意。

### 3-2. blueprint と挿入条件

- **`ProgramBlueprint.artistFeatureCornerId: String?`** を追加（`Program.swift:81-126`。program.yaml `artist_feature.corner_id`、
  nil で無効）。S14 の `guestCornerId` と同形。
- **`includesArtistFeature`** = `includesGuestCorner && artistFeatureCornerId != nil`。
  すなわち**アーティスト特集はゲストコーナーに従属**する（ゲストが入る放送＝特集も入る／ゲストが入らない放送＝特集も入らない）。
  `includesGuestCorner` は「最初の news があるとき」＝ **N ≥ 2（有限）/ エンドレス**（S14 §3）。
  - 実運用のメニュー「番組の長さ」は 10 / 20 / 30 / エンドレス（= N ≥ 10）なので、**実質どちらも必ず登場**する。
    N=2〜3 のような極小番組では特集（最長 10 数分）が番組の大半を占めるが、これは確定フロー「ニュース→ゲスト→特集」の
    帰結として**許容**する（短番組専用の抑止閾値は設けない。§17-1）。
- **実行時の従属（プール）**: 上記は plan 生成（config レベル）の条件。さらに**実行時に artists.yaml のプールが空（未生成）なら
  特集はスキップ**される（§8-4）。plan は特集を必ず 1 個置き、engine が「プール空」または「K ≤ 2」で握りつぶす。

### 3-3. 挿入ロジック（`insertionsBefore` ヘルパーに一本化）

S14 のゲスト挿入は「guest を body 4 に割り込ませ、以降の素パターン参照を `body-1` でずらす」だった。特集を body 5 に
足すと割り込みが 2 つになり、手計算の「-1 / -2」分岐は壊れやすい。**割り込みを数えて差し引く単一ロジックに統一**する。

- 位置定数: `guestBodyPosition = includesGuestCorner ? 4 : nil`、`artistFeatureBodyPosition = includesArtistFeature ? 5 : nil`。
- ヘルパー: `insertionsBefore(_ body: Int) -> Int` = `[guestBodyPosition, artistFeatureBodyPosition]` のうち
  **有効かつ `< body` の個数**を返す。
- `bodySegment(at body:)`:
  - `body == guestBodyPosition` → ゲスト talk（cornerId＝guestCornerId、S14 のまま）
  - `body == artistFeatureBodyPosition` → `ProgramSegment(kind: .artistFeature, cornerId: artistFeatureCornerId, critical: false)`
  - それ以外 → `patternBodySegment(at: body - insertionsBefore(body))`
- **端数トーク・ED 判定は「割り込みを除いた素 body 空間」で行う**（`patternBodySegment` の `pairBody`/`remainder`/ED
  判定は正規化後の body に対して動く）。これでゲストのみ有効（＝従来 `body-1`）も自動再現し、S14 既存テスト
  （`ProgramPlanTests.swift:118-172`）を壊さない。
- **`totalSegmentCount`**（`Program.swift:178-182`）: 有限番組では `includesArtistFeature ? +1`（guest と合わせ +2）。
  **エンドレスは従来どおり nil**（特集 +1 は有限のみ反映、UI 表示に影響しない）。
- **数えない**: 特集は N（トーク数）に数えない（letter / news / guest と同じ）。
- **エンドレス**: 特集は body 5 固定で**本編ループの繰り返し対象に入らず、エンドレスでも 1 回だけ**出る。

### 3-4. セグメント列の例

- N=2（guest＋特集とも有効）: `OP → song → talk → talk → letter → news → guest → 特集 → ED`
- N=3（**奇数端数 × 2 挿入**）: `OP → song → talk → talk → letter → news → guest → 特集 → talk → ED`
  （ED の絶対 index が guest/特集なし時より +2 ずれる。奇数端数 talk は素 body 空間で判定）
- N=4: `OP → song → t → t → letter → news → guest → 特集 → t → t → letter → news → ED`
  （2 回目の news 後にはゲストも特集も入らない）
- N=5: `OP → song → t → t → letter → news → guest → 特集 → t → t → letter → news → t → ED`
- 設計注記（S14 と同趣旨）: コーナー／特集は本来どこにでも置ける部品。本番組は構成意図として
  「ニュース → ゲスト → アーティスト特集」を**あえて固定**している。位置・回数を変えたい場合はこの挿入ロジックを差し替える。

### 3-5. アーティスト選定（人選のみ乱数）

放送開始時に `BroadcastEngine` が `artists.yaml` から `randomIndex(count)` で 1 組選ぶ（S14 のゲスト選定と同じ
注入可能な乱数。テストは固定値で決定論）。選定アーティストは特集セグメントの準備に渡す（§10）。

## 4. アーティスト特集ブロックの構造（`corners.yaml` に `artist_feature` コーナー追加、format: artist_feature）

頭出しリード文（時報、その日のメインが読む）→ 本編（紹介・演奏・感想の交互）→ 締め、の二層構成は他コーナーと同じ。
ただし**本編が「複数の発話パート × 最大 7 曲」**である点が新しい。

- **リード文（時報つき、その日のメインが読む）**:
  `"{ampm}{hour}時{minute}分になりました。ここからはアーティスト特集です。本日は{artist}さんを特集します。"`
  - 時刻プレースホルダの公式語彙は corners.yaml の規約に合わせる（`{ampm}` 午前/午後 ・ `{hour}` NHK 式 0-11 ・
    `{hour12}` 12 時間 ・ `{minute}` 分。`corners.yaml:8` のコメント）。**時刻は発話直前に展開**（再生時点で正確、S13.5/S14 同方針）。
  - **`{artist}` は準備時に置換**（確定済み）。置換は `ArtistFeatureEngine.prepare` 内で `featuredArtist.name` を埋める
    **新規経路**（CornerEngine の `{guest}`/`{theme}` 置換ロジックは format 分岐に紐づくので流用せず、`TimePhrases`/`TemplateExpander`
    を同じ呼び方で再利用する。共通ヘルパー化は実装時に検討）。リード文に `{theme}` は使わない（特集はテーマ不要）。
- **フロー（K=7 のフル形。話者: メイン＝当日先頭、サブ＝以降、全員＝メイン＋サブ）**:

  | # | 種別 | 内容 | 話者 | 直後の曲 |
  |---|---|---|---|---|
  | (1) | 導入（発話） | 短い特集宣言＋そのアーティストへの思いを一言 | メイン主導（サブ相づち） | — |
  | (2) | 前半グループ紹介（発話） | 1〜3 曲目をまとめて紹介（曲名・聴きどころ） | メイン主導、サブ補足 | — |
  | (3) | 前半グループ（演奏） | 3 曲を**連続再生**（曲間に発話なし） | — | 1・2・3 曲目 |
  | (4) | 感想・会話（発話） | 前半 3 曲の感想・雑談 | 全員 | — |
  | (5) | 中盤グループ紹介（発話） | 4〜6 曲目をまとめて紹介 | メイン主導、サブ補足 | — |
  | (6) | 中盤グループ（演奏） | 3 曲を**連続再生** | — | 4・5・6 曲目 |
  | (7) | 感想（発話） | 中盤 3 曲の感想（**(4) より短い**） | 全員 | — |
  | (8) | ラストグループ紹介（発話） | 7 曲目を紹介 | メイン主導 | — |
  | (9) | ラストグループ（演奏） | 7 曲目を再生 | — | 7 曲目 |
  | (10) | 締め（発話） | 「アーティスト特集でした。」で締める（固定行） | メイン | — |

  - **感想は「最後のグループを除く各グループの後」に入る**（最後のグループは演奏 → 締め）。よって K=7 では感想は (4)(7) の 2 回、
    (4) が長め・(7) が短め。**締めはグループ感想の代わりに最終グループ後へ 1 回**。縮約時の感想回数は §6。
- `CornerFormat` に **`case artistFeature = "artist_feature"`** を追加（`Dialogue.swift:44`）。
- 各曲の音量・フル再生（`play_seconds`）・連続再生・完全静寂は §8。

## 5. 曲の取得とプレフライト（Spotify top-tracks 方式、プレフライト → 台本の順）

LLM に曲名を挙げさせる方式は採らない（`SongPicker.maxCandidates=5` 固定で 7 曲に届かず、また実在曲名の保証が弱い）。
代わりに **Spotify の「アーティスト上位曲」**で実曲を確定する。

- **新規プロトコル `ArtistCatalog`（Core）**: `func topTracks(artistName: String, limit: Int) async throws -> [TrackInfo]`。
  - 実装 `SpotifyArtistCatalog`（Infra、`SpotifyWebSearcher` に同居または隣接）:
    1. `GET /v1/search?type=artist&q=<name>&market=<spotify.local.yaml の market、既定 JP>` でアーティスト ID を解決（先頭ヒット）。
    2. `GET /v1/artists/{id}/top-tracks?market=<同上>` で上位曲（最大 10）を取得。
    3. `TrackInfo`（uri/title/artist/durationSeconds）へ変換して返す。
  - `SpotifyController`/`TrackSearcher` は既存のまま。`ArtistCatalog` は別プロトコルとして注入（テストで fake 差し替え）。
- **曲の確定（プレフライト先行、CLAUDE.md §3-2）**: 台本（曲名を名指しする紹介文）を生成する**前**に確定する。手順:
  1. `topTracks(artistName:, limit: 10)` を取得。
  2. **重複除外**: 同一 URI、および**正規化タイトル（前後空白・全角半角・括弧内のバージョン表記 "Remaster"/"Live"/"feat." 等を
     除いた表記）**が一致する曲は同一曲とみなし 1 つに集約（同曲の別バージョンで枠を消費しない）。
  3. 必要なら各曲を `TrackSearcher.isPlayable` で確認（top-tracks は market 反映済みだが二重確認）。
  4. 頭から**最大 7 曲**を採用。確定実曲数を **K**（0〜7）とする。
- **フォールバック曲で水増ししない**（名指しブロックなので「紹介した曲が違う」事故を避ける）。K に応じて §6 の縮約に従う。
- top-tracks が枯渇／アーティスト未解決などで K < 3 のときは**特集をスキップ**（§6 下限・§8-4・§11）。

## 6. 縮約ルール（再生可能曲が 7 曲に満たないとき）

確定実曲数 K でグループ構成と感想回数を**決定論的に**決める。縮約は**プレフライト完了後・台本生成前**に確定する
（紹介する曲名と台本が必ず一致）。**最低曲数は 3**（導入 + 1 グループ + 締めが成立する下限）。

### 6-1. 分割アルゴリズム（擬似コード）

```
front = min(3, K)
rem   = K - front
mid   = min(3, rem)
last  = rem - mid
groups = [front, mid, last] のうち 0 を除いたもの   // 例: K=7→[3,3,1], K=6→[3,3], K=5→[3,2], K=4→[3,1], K=3→[3]
G = groups.count                                    // グループ数（1〜3）
// フロー: 導入 → for g in groups: グループ紹介 → 連続再生 → (g が最後でなければ) 感想 → 締め
// 感想は「最後のグループを除く各グループ後」。感想[0] は長め、感想[1..] は短め。締めは最終グループ後に 1 回。
```

### 6-2. 縮約表

| K | groups | G | 感想回数 | 感想で使う文字数キー | 流れ |
|---|---|---|---|---|---|
| 7 | 3+3+1 | 3 | 2 | (4)=comment / (7)=comment_short | フル（§4 の (1)〜(10)） |
| 6 | 3+3 | 2 | 1 | comment | 導入 → 3 紹介 → 3 → 感想 → 3 紹介 → 3 → 締め |
| 5 | 3+2 | 2 | 1 | comment | 導入 → 3 紹介 → 3 → 感想 → 2 紹介 → 2 → 締め |
| 4 | 3+1 | 2 | 1 | comment | 導入 → 3 紹介 → 3 → 感想 → 1 紹介 → 1 → 締め |
| 3 | 3 | 1 | 0 | — | 導入 → 3 紹介 → 3 → 締め |
| 0〜2 | — | — | — | — | **特集スキップ**（§8-4） |

- ユーザー確定フロー（短い思い導入 + 2 回目感想は短め + 締め文）は K=7 で完全充足。K=4〜6 は感想 1 回（長め）+ 締め、
  K=3 は感想なし + 締め、と段階的に痩せる（2 回目感想 `comment_short` は K=7 でのみ使用）。
- 各グループ紹介は**そのグループの実曲名・アーティスト名**を必ず正確に含む（§7）。

## 7. 台本生成

- **ペルソナ＝その日の DJ**: 出演者はその日のメイン／サブ（S13.5）。`castDjIds`（先頭＝メイン）を使う。ゲスト（S14）は登場しない。
- **発話パートごとに個別生成**: §4/§6 の発話パート（(1) 導入 / 各グループ紹介 / 各感想）を**別々の `DialogueScript`**として
  `DialogueScriptGenerator.generate` を**パート別の指示文付きで複数回**呼ぶ。`makeRequest` に「アーティスト特集の◯◯パート」
  「対象曲（複数）」を渡す薄い拡張（新パラメータ `artistFeature: ArtistFeaturePart?` 等）を加える。曲が複数なので、単曲前提の
  `song:` 引数とは別に**曲配列を扱える経路**を足す。
  - **(1) 導入**: 特集宣言＋そのアーティストへの思いを一言。短め（`intro_target_chars`）。
  - **グループ紹介 (2)(5)(8)**: 当該グループの各曲を順に「曲名／聴きどころ」をまとめて紹介。メイン主導・サブ補足
    （`group_intro_target_chars`）。**渡した曲名・アーティスト名を一字一句そのまま発話し、言い換え・推測の別情報を加えない**
    制約を明記（曲名の改変・捏造を防ぐ。`DialogueScriptGenerator` の「曲名を明かさず…」分岐は使わない）。
  - **感想 (4)(7)**: グループを聴いた体での感想・雑談（全員）。(4)=`comment_target_chars`、(7)=`comment_short_target_chars`
    （(7) は (4) より小さい目標。§6/§13）。
  - **(10) 締め**: 「アーティスト特集でした。」を含む**固定行**。LLM 生成しない（`DialogueScriptParse` の 4 行下限
    `DialogueScriptGenerator.swift:139` に抵触するため。corners.yaml `outro_line`、既定「アーティスト特集でした。」を
    メインの `DialogueLine` として直接積む）。
- **文字数下限縛り**: 各 LLM パートは既存の「N 文字以上 N×1.2 文字以内」制約（`DialogueScriptGenerator.makeRequest:92`）を踏襲。
  目標文字数は corners.yaml にパート別に持つ（§13）。短すぎる台本は不可。
- **4 行下限対策**: 導入・紹介・感想は**メイン＋サブの対話（複数ターン）**として生成するため 4 行下限を満たす。締めのみ固定行。
- **挨拶抑制**: 特集は番組途中なので挨拶・自己紹介・番組名の名乗りはしない（`greeting = nil`、`makeRequest:100-102` の
  「途中のコーナー」分岐踏襲）。
- **1 曲ずつの曲振りは行わない**（ユーザー確定: グループ単位でまとめて紹介 → 連続再生）。
- **季節・日付コンテキスト**: `SeasonPhrases.dateContext`（`CornerEngine.prepare:106` と同じ注入）を各パートのプロンプトへ。

## 8. 連続再生・完全静寂・先行準備・ED 早終了

### 8-1. 連続再生（CLAUDE.md §3-1）

- グループ内の各曲は **`spotify.play(uri) → setVolume(corner.volume) → waitForTrackToFinish(of: uri)`** を順に実行する
  （`CornerEngine.perform:222-231` の単曲再生をループ適用）。`play_seconds > 0` なら固定秒、既定 0 はフル再生・終端検知
  （早切り／過走防止、S10/S12 fix を流用）。
- **曲間は pause しない**（`WebApiSpotifyController.play` は queue をアトミック置換するため、`play(next_uri)` で直接切替）。
  これで「曲間に発話なし＝シームレス」を満たす。曲間ギャップは `endPollSeconds`（0.5 秒）＋ play レイテンシ程度（< 1 秒目標）。
- **各曲 play 直後に必ず `setVolume(corner.volume)`** を呼ぶ（発話 → 曲、曲 → 曲の遷移で音量が確実に曲用へ戻る）。

### 8-2. 完全静寂の絶対保証

- 特集ランナー `run` は **正常・例外・キャンセルのいずれでも最後に必ず `pause()`**（`CornerEngine.run:177-190` と同じ
  do/catch + `pauseIgnoringCancellation(restoringVolume:)` + 末尾 `pause()`）。各 await 点で `CancellationError` を伝播。
- **連続再生中のキャンセルは「最後に play した URI」を pause すれば一意に止まる**。`run` は内部で**現在再生中 URI を追跡**し、
  do/catch は**全曲・全発話パートを 1 つで包む**。どの曲・どの await でキャンセルされても catch の `pauseIgnoringCancellation`
  1 回で現在音が止む（停止ボタンから 1 秒以内に無音）。
- **音量復元先**は `CornerEngine` の先例に合わせ **corner.volume**（特集コーナーの volume）に復元する（コーナー単位の音量規約）。
  停止後始末でも音量をフルへ戻す既存方針と整合（実運用は 100）。

### 8-3. 先行準備（重い準備の前倒し）

- 特集セグメントは 1 つで「最大 7 曲の top-tracks 取得＋プレフライト＋複数パート台本＋全行 TTS 事前合成」という、通常 talk の
  数倍〜十数倍の準備量を持つ。ローリング窓（`preparationWindow=2`）だけでは直前セグメント（news 等、数十秒〜数分）の
  再生中に間に合わない恐れがある。
- よって**特集の準備は放送開始時に先行起動**する（アーティストと当日キャストは開始時に確定済み。S10 で冒頭曲・初手トークを
  開始時に先出しするのと同方針）。特集セグメントに到達するまで（OP→冒頭曲→トーク→トーク→お便り→ニュース＝数分）の
  リードタイムがあるため十分間に合う。準備物は `PreparationLedger` に `artistFeatureTask: Task<PreparedArtistFeature, any Error>`
  で保持（`cornerTasks` と同形、`BroadcastEngine.swift:423` の existential `any Error` 表記に合わせる）。
- 準備内部は重いので **top-tracks 取得・各パート台本生成・各行 TTS 合成を `TaskGroup` で並行化**してよい（決定論が要るのは
  選定 RNG のみ。曲順は top-tracks の順を保つ）。
- 「放送開始前の無音は許容、放送中の長い無音ゼロ」（既存原則）に従い、万一到達時に未完了なら待つ（特集直前の許容デッドエア
  上限は実装時に観測して調整。間に合わない構成なら §17 で再検討）。

### 8-4. 特集スキップの契約（決定論 plan × 実行時スキップ：空プール / K ≤ 2）

`ProgramPlan` は決定論的に**特集セグメントを必ず 1 個**置く（§3）。実際に流すかは実行時の**プール有無**と **K** に依存する。責務分界:

- **plan = 必ず置く / engine = 実行時に握りつぶす**。
- **プール空（artists.yaml 未生成）**: 放送開始時にアーティストを選定できないので、準備物を**スキップ状態**にする
  （reason に安定コード `E-ART-EMPTY-POOL-001`）。
- 準備（`prepare`）で K ≤ 2 と判明したら、準備物に**スキップ状態**を持たせる（reason `E-ART-INSUFFICIENT-TRACKS-001`）。
- `perform` の `.artistFeature` は、スキップ状態なら **`segmentStarted` を出さず**、`ArtistFeatureEvent.featureSkipped(reason)`
  ＋ `segmentFinished` を出して**音を出さず即次へ**。`segmentFailed` には乗せない（事故ではない）。`totalSegmentCount` は特集を
  最大 1 として数えるため、スキップ時に UI 表示が 1 多く見えうる点は許容（将来 UI 補正は §16）。

### 8-5. ED 早終了との相互作用

既存 ED 早終了（`BroadcastEngine.swift:185-205`）は「現セグメント＋準備完了済みの**直後 talk**（`kind==.talk` かつ
`cornerId==talkCornerId`）だけ流して ED」。特集は `.artistFeature` なのでこの「直後 talk」条件に**合致しない**。

- **news 直後に ED ボタン**（特集・ゲストがまだ開始前）: 既存どおりゲストも特集も `cancelAll()` で破棄して ED へ（許容）。
- **特集再生中に ED ボタン**: 特集は 1 ブロックとして**最後まで流し切ってから ED**（既存規約「現セグメントを流し切ってから
  ED」と整合）。**特集の直後の talk（body 6 以降の素 talk）は keeping 対象にしない**（特集後に余分なトークが 1 本挟まって
  から ED、を防ぐ）。実装は「直前に流したセグメントが `.artistFeature` のときは『直後 talk を流す』分岐に入らず ED へ直行」。
- **停止（Stop / Ctrl-C）**: §8-2 のキャンセル経路で即時無音。

## 9. `artists.yaml` と 100 名 LLM 生成（メニューバーのボタン）

### 9-1. `config/artists.yaml`（新規、コミット可・機密でない）

- 場所・命名: `config/artists.yaml`（kebab-case ファイル・snake_case キー、CLAUDE.md §3-4）。
- スキーマ（最小）:
  ```yaml
  artists:
    - id: artist_001          # 安定 id（重複排除キー）。生成ボタンが連番採番（§9-3）
      name: "米津玄師"          # 表示・検索・台本に使う正式名
      # reading: "よねづけんし" # 任意。VOICEVOX 読み崩れ対策（当面は name のみ、§17-3）
  ```
- 各エントリは **id（一意）/ name（必須）**。`ArtistProfile`（§10）に対応。曲は持たない（曲は実行時に top-tracks で確定）。
- **出荷時は空**（`artists: []` または ファイルなし）。メニューの生成ボタン（§9-3）で作成・上書きする。空のときは特集スキップ（§8-4）。

### 9-2. `ArtistsConfigLoader`（新規、Infra）

- S14 の `GuestsConfigLoader`（`Sources/AIRadioInfra/GuestsConfig.swift`）と同形:
  `enum ArtistsConfigLoader { private struct File/Artist; load(yaml:) / load(path:) -> [ArtistProfile] }`。
- **空・未生成は正常**（出荷時は空）: ファイルが無い、または `artists:` が空なら**空配列を返す**（エラーにしない）。
  プールが空のときは実行時に特集をスキップする（§8-4、`E-ART-EMPTY-POOL-001`）。
- **壊れているのは fail-fast**: ファイルが存在して**パース不能 / name 欠落 / id 重複 / 正規化 name 重複**のときは
  `ConfigError`（既存 CFG カテゴリ）を投げる（CLAUDE.md §4-3。`BroadcastWiring.swift:74-76` の「存在するのに壊れていれば throw」を踏襲）。

### 9-3. メニューバーの「アーティスト一覧を生成」ボタン（生成手段はこれに一本化）

- メニューバー（`MenuBar`）に **「アーティスト一覧を生成」** 項目を追加。生成ロジックは共通関数 `ArtistListGenerator`（仮）に
  まとめ、**トリガはこのボタンのみ**（CLI デモ `gen-artists` は作らない）。
- **状態ゲート**（`BroadcastSession` に `generatingArtists` 状態を追加、または App 側で排他）:
  - ボタンは**放送停止時（idle）のみ有効**。放送中は無効（グレーアウト）。
  - **生成中は「放送を開始」を無効化**＋メニューに「アーティスト生成中…」を表示。生成と放送は相互排他。
  - 状態遷移: `idle →(クリック)→ generatingArtists →(完了/失敗)→ idle`。完了で表示を戻す（簡単な完了表示）。
- **生成設定はファイル（`config/artist-gen.yaml`）から読む**（ハードコードしない・UI 不要）: `genre_prompt`（ジャンル/スコープの
  自由記述。既定は邦楽。洋楽・クラシック等に書き換え可）と `target_count`（プールに保存したい組数。既定 100。20 でも可）。§13。
- **動作**: Gemini（`GeminiLLMBackend`、既存 `llm.yaml`/`llm.local.yaml`）に **`genre_prompt` のジャンル**でアーティストを挙げさせ、
  検証のうえ `config/artists.yaml` を**上書き**する（Yams でエンコード、**一時ファイル → rename** で原子的に置換）。生成に TTS・
  再生デバイスは不要（LLM＋Spotify 検索のみ。Spotify 認証・market は既存設定を使う）。
  - プロンプト方針: 「**{genre_prompt}** に該当するアーティストを 1 行 1 組『アーティスト名』のみ。実在し Spotify 配信のある
    有名どころ中心。重複・別表記を避ける」。**目標 `target_count` 名**だが、去重・検証で減るのを見越して**多めに要求**（例 `×1.3`）。
  - **去重**: 正規化（前後空白・全角半角・記号差）した name で去重。
  - **実在の検証**: 去重後、各 name で `ArtistCatalog.topTracks`（または artist 検索）を 1 回かけ、**曲がヒットしないエントリは捨てる**
    （非実在・配信なし・検索に出ない名前を生成時点で間引く。ジャンル非依存）。
  - **件数**: `target_count` を目標にベストエフォート。大きく不足なら追加生成を最大 N 回リトライ。最終件数をログ
    （プールは 1 組以上で成立。0 組なら下記「失敗時」）。
  - **id 採番**: 安定連番 `artist_001…`（ローマ字 slug は §17-4）。
  - **上書き**: 既存 `artists.yaml` は**常に全置換**（append/merge はしない。ユーザー確定）。
  - **失敗時**: LLM 不調・検証全滅（0 組）などは**ファイル不変**＋エラー表示で idle に戻る（既存ファイルを壊さない）。
- 生成はバックグラウンド Task。完了/失敗まで放送開始はブロックされる。生成のキャンセル可否は実装時に検討（最低限ハングしない）。

## 10. 新規 Core/Infra 型と既存パターンの流用

### 10-1. Core（`AIRadioCore`）

- `enum SegmentKind` に `case artistFeature`（§3-1）。
- `enum CornerFormat` に `case artistFeature = "artist_feature"`（`Dialogue.swift:44`）。
- `struct ArtistProfile { id: String; name: String /*; reading: String?*/ }`（`DjProfile` 隣、`Dialogue.swift`）。
- `ProgramBlueprint.artistFeatureCornerId: String?` ＋ `ProgramPlan`（`includesArtistFeature` / `artistFeatureBodyPosition` /
  `insertionsBefore` / `bodySegment` 拡張 / `totalSegmentCount`）（§3、`Program.swift`）。
- **特集セグメントの選定アーティスト受け渡し**: `CornerContext` には足さず、`ArtistFeatureRunning.prepare` に
  `featuredArtist: ArtistProfile` を**直接引数で渡す**（talk 系の `CornerContext` は据え置き、責務を混ぜない）。
- **`protocol ArtistCatalog`**（§5）: `topTracks(artistName:limit:) -> [TrackInfo]`。
- **マルチ曲の準備物・ランナー**:
  - `struct PreparedArtistFeature`: `corner: CornerTemplate`、`artist: ArtistProfile`、`groups: [[TrackInfo]]`（縮約後の
    曲グループ。例 `[[t1,t2,t3],[t4,t5,t6],[t7]]`）、`partScripts: [DialogueScript]`（発話パート別台本）、`partAudio: [[Data]]`
    （パート別の事前合成音声）、`castDjIds: [String]`、`leadIn: String`（{artist} 置換済み・時刻のみ残す）、`leadInSpeakerId: Int`、
    `outroLine: DialogueLine`（固定締め）、`skipped: Bool`（K≤2）、`skipReason: String?`。
    （`PreparedCorner`（`CornerEngine.swift:20`）のマルチ曲版。後方互換のため**別型**とし、既存単曲経路は不変。）
  - `protocol ArtistFeatureRunning`（`prepare(corner:artist:castDjIds:leadIn:dateContext:onEvent:) -> PreparedArtistFeature` /
    `run(prepared:djs:)`）と実装 `ArtistFeatureEngine`。`CornerRunning`/`CornerEngine`（`Protocols.swift:167`、`CornerEngine.swift:60`）
    と同じ「prepare（無音・catalog/LLM/TTS）/ run（発話＋連続再生＋必ず pause）」二段構成・依存注入
    （llm/tts/audio/catalog/spotify/clock/randomIndex/onEvent）。run は**現在再生中 URI を追跡**（§8-2）。
  - `enum ArtistFeatureEvent`（`CornerEvent` 相当）: `artistSelected(name)` / `tracksPrepared(count)` /
    `partScriptReady(partIndex, lineCount, chars)` / `leadIn(text)` / `line(DialogueLine)` / `songStarted(TrackInfo)` /
    `songFinished(reason)` / `featureSkipped(reason)`。
- `DialogueScriptGenerator.makeRequest` にアーティスト特集パート用の薄い分岐（曲配列・パート種別・曲名原文一致制約、§7）。

### 10-2. BroadcastEngine（`BroadcastEngine.swift`）

- `run(..., artists: [ArtistProfile] = [])` を追加（S14 が `guests:` を足したのと同形、`:66-72`）。
- fail-fast 検証＋選定（ゲスト検証 `:87-105` の直後）: `artistFeatureCornerId` 設定かつ `plan.includesArtistFeature` のとき、
  (a) 特集 corner template の存在、(b) `artistFeatureCornerId` が **talk/letter/guest の cornerId いずれとも異なる**こと、
  (c) プール非空、を検証（不正は `ConfigError`＝既存 CFG カテゴリ、§11）。`artists[randomIndex(count)]` で選定。
- `perform`（`:266-322`）に `case .artistFeature:` を追加。先行準備した `artistFeatureTask` を `ledger` から取り出し、
  スキップ状態なら §8-4、そうでなければ `artistFeatureRunner.run(prepared:djs:)`。
- `cornerContext`（`:385-408`）は特集に使わない（特集は専用 prepare 引数）。`startPreparation`（`:325-363`、または開始時先出し
  §8-3）に特集準備の起動を追加。
- `PreparationLedger`（`:421-474`）に `artistFeatureTask: Task<PreparedArtistFeature, any Error>?`（または index キー）を追加
  （`cornerTasks` と同じ add/get/discard/cancelAll）。
- ED 早終了の「直前が `.artistFeature` なら直後 talk を流さず ED 直行」分岐（§8-5）。

### 10-3. Infra / App

- Infra: `SpotifyArtistCatalog`（§5、`ArtistCatalog` 実装）、`ArtistsConfigLoader`（§9-2）、`ArtistGenConfig`/`ArtistGenConfigLoader`
  （`config/artist-gen.yaml`、§13。欠落時は既定値）。`CornersConfigLoader` は
  `format: artist_feature` を `CornerFormat` の raw 値追加で自動デコード（loader 改修は最小、要確認）。
- App `BroadcastWiring`（`:62-136`）: `artists.yaml` を読んで `engine.run(..., artists:)` に渡す（空なら空配列）。
  `ArtistFeatureEngine`/`SpotifyArtistCatalog` を DI 配線（`:91-100` 近辺）。`BroadcastStack.artists: [ArtistProfile]` を追加
  （`:46-58`）。`printArtistFeatureEvent`（`printCornerEvent:139-160` と同形・default なし exhaustive）を追加。
- App `MenuBar` / `BroadcastSession`: **「アーティスト一覧を生成」メニュー項目**＋`generatingArtists` 状態を追加（§9-3。
  放送と相互排他）。生成ロジックは共通関数 `ArtistListGenerator`（LLM＋`ArtistCatalog`→検証→artists.yaml 原子的上書き）。
  `main.swift` の `AIRADIO_DEMO` には**追加しない**（CLI 生成は作らない）。
- program.yaml: `artist_feature:\n  corner_id: artist_feature`（消すと無効）。
- corners.yaml: `id: artist_feature`（format: artist_feature、lead_in、`outro_line`、パート別目標文字数キー §13）。
- `config/artists.yaml`: **出荷時は空**。メニューの生成ボタンで約 100 名を作成・上書き（§9-3）。

## 11. エラーコード

新カテゴリ **ART（アーティスト特集）**は**実行時の特集スキップ専用**。起動時の設定不正は既存 **CFG** に寄せる。

| コード | カテゴリ | 発生条件 | 扱い |
|---|---|---|---|
| `E-ART-INSUFFICIENT-TRACKS-001` | ART | 再生可能曲が最低 3 曲に満たず（K ≤ 2）、特集ブロックをスキップ | **fail-tolerant・throw しない**。`featureSkipped(reason)` のログ用安定コード |
| `E-ART-EMPTY-POOL-001` | ART | `artist_feature.corner_id` 設定だが artists.yaml が空／未生成 → 特集スキップ | **fail-tolerant・throw しない**。`featureSkipped(reason)` のログ用安定コード |
| `E-CFG-MISSING-FIELD-001`（既存） | CFG | `artist_feature.corner_id` 設定時に corner template 不在 / id 衝突（talk/letter/guest と重複）/ artists.yaml が**壊れている**（空は除く） | fail-fast（起動エラー、`ConfigError`） |

- `E-ART-INSUFFICIENT-TRACKS-001` は `BroadcastEvent.segmentFailed` には**乗せない**（実行時エラー専用イベントと混同しない）。
  `ArtistFeatureEvent.featureSkipped(reason)` ＋情報ログに一本化。特集セグメントの `critical` は常に `false`。
- 縮約（K=3〜6）はエラーではなく正常動作（情報ログのみ）。プレフライト個別失敗は既存 fail-tolerant に倣いコード化しない。
- `docs/specs/error-codes.md` の台帳と CLAUDE.md §4-3 のカテゴリ列挙（CFG/RTM/SPT/TTS/LLM/NEWS/WX/RES）に **ART** を追加。

## 12. テスト方針（決定論・fake 差し替え、CLAUDE.md §4-4）

- **`ProgramPlan`**（`ProgramPlanTests.swift`）: `artistFeatureCornerId` 設定で **N=2 / 3（奇数）/ 4 / 5 / エンドレス**に
  「ゲスト直後 1 個だけ」特集を挿入、2 回目 news 後は無し、guest 無効時は特集も無し、`totalSegmentCount` が +1（guest と合わせ +2、
  エンドレスは nil）、N に数えない、index ずらし（guest body4 / 特集 body5 / 以降 `insertionsBefore` で正規化、ED・端数 talk の位置）。
- **`BroadcastEngine`**: `artists` を `randomIndex` 固定で 1 組選定（決定論）、特集準備に選定アーティストが渡る、
  fail-fast（id 衝突＝`artistFeatureCornerId==guestCornerId` 等 / template 不在 / artists.yaml 壊れ）、1 放送ちょうど 1 回、
  K ≤ 2 で `featureSkipped`（`E-ART-INSUFFICIENT-TRACKS-001`、`segmentFailed` は出ない）＋放送継続、
  **プール空で `featureSkipped`（`E-ART-EMPTY-POOL-001`）＋放送継続**、ED 早終了（**特集再生中の ED で特集を流し切り→ED、余分な
  トークが挟まらない** / news 直後 ED で特集破棄は許容）。
- **生成ボタン・状態ゲート**（App）: 放送中はボタン無効、生成中は「放送を開始」無効（相互排他）、生成は artists.yaml を原子的に
  上書き、失敗時はファイル不変。`ArtistsConfigLoader` は空＝空配列／壊れ＝throw。
- **`SpotifyArtistCatalog` / `ArtistCatalog`**（新規）: fake で artist 解決→top-tracks→TrackInfo 変換、重複（同 URI・正規化タイトル）
  除外、最大 7、候補不足時は集まった数だけ返す。
- **`ArtistFeatureEngine`**（fake llm/tts/audio/catalog/spotify/clock）: 7→3+3+1 の分割、縮約（6/5/4/3/≤2）と感想回数、
  リード文 {artist} 置換＋時刻は run 時展開、パート別台本（(7) が (4) より短い目標 / 紹介に**確定曲名が原文一致で含まれる** /
  締めは固定行「アーティスト特集でした。」）、連続再生の曲順・曲数・**各曲 play 後 setVolume**、
  キャンセル（**1 曲目再生中 / 1→2 曲目遷移直後 / 3 曲目再生中**の 3 点）でいずれも `pauseIgnoringCancellation` が呼ばれ
  1 秒以内無音（fake spotify の pause 呼出記録で検証）、例外でも必ず pause、停止後の音量復元。
- **`ArtistsConfigLoader`**: 正常 / 必須欠落（name）/ id 重複 / 正規化 name 重複 / 壊れた yaml / ファイル非存在。
- **`DialogueScriptGenerator`**: artistFeature パートで曲名原文一致・締め文言の制約が入ること、guest/letter/freeTalk の既存挙動
  不変（回帰）。
- **先行準備**（fake clock）: 特集準備が特集到達前に完了する（直前セグメント再生中に間に合う）。
- **回帰（不変）**: S14 ゲスト挿入、完全静寂、ローリング準備、ED ボタン、時報リード文の時刻正確性、S13.5 曜日替わり。
  アーティスト生成ボタンは放送と相互排他で、放送系ロジックには影響しない。
- 完了条件: `swift build` / `swift test` 全グリーン。

## 13. 設定（命名規約）

- ファイル: `config/artists.yaml`（kebab-case、**出荷時は空＝出力**、生成ボタンで作成・上書き）。キー: `artists` / `id` / `name` / 任意 `reading`（snake_case）。
- ファイル: `config/artist-gen.yaml`（kebab-case、**コミット済み＝入力**、生成ボタンの設定）。キー: `generation.genre_prompt`
  （ジャンル/スコープの自由記述、既定は邦楽）/ `generation.target_count`（既定 100）。**ジャンル・件数はここで変える**
  （洋楽・クラシック等）。検証・runtime の market は既存 `spotify.local.yaml` の market を流用（このファイルには持たない）。
- program.yaml: `artist_feature.corner_id`（snake_case、S14 の `guest.corner_id` と並ぶ）。
- corners.yaml（`id: artist_feature`、`format: artist_feature`）:
  - `lead_in`（リード文、{artist}＋時刻プレースホルダ）
  - `outro_line`（固定締め、既定「アーティスト特集でした。」）
  - パート別目標文字数（snake_case で確定）: `intro_target_chars` / `group_intro_target_chars` /
    `comment_target_chars` / `comment_short_target_chars`。
  - **`comment_short_target_chars < comment_target_chars` をロード時に検証**（違反は fail-fast。「2 回目感想は短め」を機械担保）。
  - `volume` / `play_seconds`（既存コーナーと同様、全曲共通）。
- コード識別子は英語（型 UpperCamelCase / 変数 lowerCamelCase）。日本語表示文字列は YAML に集約（CLAUDE.md §4-1）。
- 機密値なし（`artists.yaml` はコミット可。`.local.yaml` 不要）。

## 14. 実装チェックリスト

- [ ] Core: `SegmentKind.artistFeature`（+ 網羅 switch 全数監査 grep）/ `CornerFormat.artistFeature`。
- [ ] Core: `ArtistProfile`。特集の選定アーティストは `ArtistFeatureRunning.prepare` 引数で受け渡し（CornerContext 不変）。
- [ ] Core: `ProgramBlueprint.artistFeatureCornerId` ＋ `ProgramPlan`（`includesArtistFeature` / `insertionsBefore` /
      body5 挿入 / `totalSegmentCount` / エンドレス）。
- [ ] Core: `protocol ArtistCatalog`（top-tracks）。
- [ ] Core: `PreparedArtistFeature` / `ArtistFeatureRunning` / `ArtistFeatureEngine`（prepare で top-tracks→重複除外→
      プレフライト→縮約確定→パート別台本→事前合成、run で連続再生＋現在 URI 追跡＋必ず pause）/ `ArtistFeatureEvent`。
- [ ] Core: `DialogueScriptGenerator.makeRequest` に特集パート分岐（曲配列・曲名原文一致・(7)<(4) 文字数）。締めは固定行。
- [ ] Core: `BroadcastEngine`（`run(artists:)` / fail-fast＋選定 / `perform` の `.artistFeature` ＋スキップ契約 /
      開始時の特集準備先出し / `PreparationLedger` に特集タスク / ED 早終了の特集分岐）。
- [ ] Infra: `SpotifyArtistCatalog`（artist 検索→top-tracks、market=JP）/ `ArtistsConfigLoader`（空＝空配列・壊れ＝throw）。
- [ ] App: `BroadcastWiring`（`artists.yaml` 読込→`run(artists:)`、`ArtistFeatureEngine`/`SpotifyArtistCatalog` 配線、
      `BroadcastStack.artists`、`printArtistFeatureEvent`）。
- [ ] App: `MenuBar`＋`BroadcastSession` に「アーティスト一覧を生成」ボタン＋`generatingArtists` 状態（放送と相互排他）＋
      共通生成関数 `ArtistListGenerator`（`artist-gen.yaml` の genre_prompt/target_count を読む → LLM→検証→artists.yaml 原子的上書き）。
      CLI 生成は作らない。
- [ ] config: `program.yaml` に `artist_feature.corner_id` / `corners.yaml` に `artist_feature` コーナー /
      `config/artist-gen.yaml`（genre_prompt 既定=邦楽・target_count=100、コミット）/ `config/artists.yaml` は出荷時空（生成ボタンで作成・上書き）。
- [ ] docs: `error-codes.md` に `E-ART-INSUFFICIENT-TRACKS-001`、CLAUDE.md §4-3 に ART カテゴリ追加。
- [ ] Tests: ProgramPlan / BroadcastEngine / ArtistCatalog / ArtistFeatureEngine / ArtistsConfigLoader /
      DialogueScriptGenerator / 先行準備 / 回帰一式。`swift build` / `swift test` 全グリーン。

## 15. 受け入れ条件

- `swift build` / `swift test` 全グリーン。
- 放送中、ゲストコーナーの直後に 1 回だけアーティスト特集が入り、「{時刻}になりました。ここからはアーティスト特集です。
  本日は〈アーティスト〉さんを特集します」で始まり、§4 の (1)〜(10)（または §6 の縮約形）で進み、最後に
  「アーティスト特集でした。」で締める（ユーザー確認）。
- 名指しした曲（最大 7、縮約後の実曲）は**すべてプレフライト済みで実際に流れる**（紹介と再生が一致、§3-2）。紹介台本の曲名は
  実曲名と一致する。
- 再生可能曲が 3 曲未満のときは特集をスキップし、`E-ART-INSUFFICIENT-TRACKS-001` をログに残して放送継続（`segmentFailed` を
  出さない）。
- アーティスト特集は 1 放送 1 回（2 回目以降の news 後には入らない）。
- 連続再生で曲間に発話・長い無音がなく、停止時は 1 秒以内に無音（完全静寂）。
- メニューの「アーティスト一覧を生成」ボタン（放送停止時のみ有効）で、`config/artist-gen.yaml` の `genre_prompt`/`target_count`
  に従って `config/artists.yaml`（去重・実在検証済み・重複なし）が**上書き**される（既定は邦楽・100 名、洋楽・クラシック等に変更可）。
  生成中は放送開始が無効。プールが空（未生成）の放送では特集をスキップ（`E-ART-EMPTY-POOL-001`）して継続。

## 16. スコープ外（将来）

- アーティスト特集の**位置可変・複数回**（現状はゲスト直後固定・1 回）。
- K ≤ 2 時の**別アーティスト引き直し**（現状はスキップ）。
- アーティストの**テーマ／ジャンル連動選定**（現状はランダム）。
- スキップ時の UI カウント補正、`TrackFinishReason` の UI 露出。
- `artists.yaml` への `reading`（TTS 読み）追加。

## 17. 要確認（残論点・既定の確定理由つき）

1. **特集をゲスト無効でも単独で入れるか** — 本仕様: **ゲストに従属**（同時に出る）。構成意図「ニュース→ゲスト→特集」を優先。
   短番組専用の抑止閾値は設けない（実運用は N ≥ 10）。
2. **K ≤ 2 の挙動** — 本仕様: **引き直さずスキップ**（決定論・簡潔性）。
3. **`artists.yaml` の TTS 読み（`reading`）** — 本仕様: **当面 name のみ**。読み崩れが目立てば任意フィールドで追加（後方互換）。
4. **生成の id 採番とジャンル・件数** — 本仕様: **連番 `artist_001`**。**ジャンル（`genre_prompt`）と件数（`target_count`）は
   `config/artist-gen.yaml` で指定**（既定: 邦楽中心・100 名。洋楽・クラシック等に変更可、ハードコードしない）。生成手段は
   **メニューボタンに一本化**（CLI なし）。
5. **曲取得を top-tracks に変更**（当初の「LLM に曲名を挙げさせる」案からの変更） — 本仕様: **Spotify top-tracks** を採用
   （7 曲確保の確実性・実曲名の正確性のため。`ArtistCatalog` プロトコル新設、§5）。
6. **生成の起動方法・初期状態・上書き**（ユーザー確定 2026-06-13） — メニューバーの「アーティスト一覧を生成」ボタン（放送停止時のみ）。
   `artists.yaml` は**出荷時は空**で、空のときは特集スキップ（fail-fast にしない）。ボタンは**常に全置換（上書き）**。生成と放送は相互排他。
