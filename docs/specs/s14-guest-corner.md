# S14 — ゲストコーナー（1 放送 1 回、最初のニュースの直後に固定）

## 1. 概要

1 放送に 1 回だけ、**最初のニュース＋天気予報の直後**にゲストコーナーを挿入する。その日の編成
（メイン＋サブ）＋**ゲスト 1 名**の会話。ゲストは VOICEVOX の**非レギュラーキャラのプールからランダム**
に選ぶが、台本上は**「本日のテーマに詳しいゲスト」という建付け**にする（テーマ連動の選定ロジックは持たない＝
誰が来てもそのテーマの専門家として登場）。`DialogueScriptGenerator` は任意人数対応済みなので、cast 末尾に
ゲストを足すだけで 3 人（日曜は 4 人）会話になる。

## 2. ゲストプール（`config/guests.yaml`、新規）

- レギュラー（zundamon / metan / tsumugi / ryusei）を**除く** VOICEVOX 非レギュラーキャラ。
- 各ゲスト: `id` / `name` / `speaker_id`（/speakers で実在確認）/ `persona`（口調・キャラ。伸ばす音は「ー」、「〜」不可）。
- **建付け**: 選ばれたゲストは台本上「本日のテーマに詳しい人」として扱う（persona に専門分野は書かない）。
- 初期メンバー（実装時に /speakers で再確認。ユーザー編集・追加可）:
  | id | name | speaker_id | persona（要旨） |
  |---|---|---|---|
  | sora | 九州そら | 16 | おっとり穏やか、丁寧な敬語 |
  | takehiro | 玄野武宏 | 11 | 爽やかで頼れる青年、はきはき |
  | kotarou | 白上虎太郎 | 12 | 元気いっぱいの少年、好奇心旺盛 |
  | himari | 冥鳴ひまり | 14 | 落ち着いた知的な女性、ふんわり |
  | mochiko | もち子さん | 20 | マイペースでほんわか |
  | no7 | No.7 | 29 | クールで理知的、アナウンサー的 |
  | zunko | 東北ずん子 | 107 | しっかり者で優しいお姉さん |
  | kiritan | 東北きりたん | 108 | クールで少しツンとした、芯のある女の子 |
  | itako | 東北イタコ | 109 | 落ち着いた大人の女性、包容力 |
  | ankomon | あんこもん | 113 | **語尾に「もん」を付ける独特の口調**（例:「おいしいもん」「気になるもん」）。甘いもの好きで素直、好奇心旺盛（ずんだもんの「なのだ」に匹敵する特徴） |
- `GuestsConfigLoader`（`guests:` キー → `[DjProfile]`。`DjsConfigLoader` と同形）。
- fail-fast: `program.guest.corner_id` を設定した場合、プールが空、または id がレギュラー（djs）と衝突するとエラー。

## 3. 配置（`ProgramPlan` が生成、固定位置・1 回）

「ランダム枠選択」は**廃止**。位置は決定論的に固定する。

- ゲストコーナーは**最初の news セグメントの直後**に 1 つだけ挿入される（2 回目以降の news 後には入らない）。
- 最初の news が存在するのは本編に 1 グループ目（`talk, talk, letter, news`）がある場合＝**N ≥ 2**（有限）/ エンドレス。
  N ≤ 1（news なし）ではゲストコーナーも無し（ただし実運用の番組の長さは最小 10 なので、実質ゲストは必ず登場する）。
- **設計上の注記**: コーナーはもともと自由に配置できる部品であり、ゲストコーナーも本来は番組内のどこにでも挿入可能。
  本プログラムでは**あえて「最初のニュースと天気予報の次」に固定**している（番組が一度ニュースで締まった直後に
  ゲストを迎えるという構成上の意図）。将来この位置を変えたい / 複数回にしたい場合は、この配置ロジック
  （`ProgramPlan` の「最初の news 直後に挿入」）を差し替えればよい。
- `ProgramBlueprint.guestCornerId: String?`（program.yaml `guest.corner_id`、nil で無効）。
- `ProgramPlan` は guestCornerId が設定され最初の news があるとき、本編 body の「最初の news の次」に
  ゲスト talk セグメント（`kind: .talk`, `cornerId: guestCornerId`）を 1 つ挿入し、以降の index を 1 つ後ろにずらす。
  `totalSegmentCount` も +1。**ゲストは N（トーク数）に数えない**（letter / news と同じ扱い）。
- 例（N=2）: OP → song → talk → talk → letter → news → **guest** → ED。
  例（N=4）: OP → song → t → t → letter → news → **guest** → t → t → letter → news → ED（2 回目 news 後にゲストなし）。
- **ゲストの人選のみ乱数**: 放送開始時に `BroadcastEngine` がプールから 1 名選ぶ（乱数注入でテスト決定論）。

## 4. ゲストコーナーの構造（`config/corners.yaml` に `guest` コーナー追加、format: guest）

頭出しリード文（時報、その日のメインが読む）→ 本編ダイアログ（LLM）→ 締め曲、の二層は他コーナーと同じ。

- **リード文（導入の口上、ユーザー指定）**:
  `"{ampm}{hour}時{minute}分になりました。次はゲストコーナーです。本日は{guest}さんを迎えて、{theme}について熱く語ってもらいます。"`
  - **時刻**（{ampm}/{hour}/{minute}）は発話直前に展開（再生時点で正確、S13.5 と同じ）。
  - **{guest}（ゲスト名）/ {theme}（選択テーマ）は準備時に埋め込み**（確定済みのため）。`CornerEngine.prepare` で
    `{guest}`→ゲスト名、`{theme}`→選択テーマを置換し、時刻プレースホルダのみ残して `PreparedCorner.leadIn` に格納。
  - 読み手はその日のメイン（S13.5 のリード文と同じ）。
- **本編ダイアログ**（メイン主導、cast 末尾にゲスト）:
  リード文で紹介済みのため、ゲストが軽く挨拶 → 全員でテーマ会話（メイン進行・サブは相槌/質問・**ゲストは専門家として詳しい話**）
  → 最後にメインがゲストへお礼 → 締め曲へ曲振り。
- `CornerFormat` に `.guest` 追加。`CornerContext.guest: DjProfile?`（非 nil＝ゲストコーナー、選定ゲスト）。
- `CornerEngine.prepare`（format: guest）: cast = 当日 cast ＋ [guest]（末尾）。テーマはプールから選択。
  選曲はテーマ基準（プレフライト従来どおり）。リード文の {guest}/{theme} 置換。台本生成にゲスト挨拶・お礼・専門家フレーミングを指示。
- `DialogueScriptGenerator.makeRequest`: `guest: DjProfile?` を受け、非 nil のとき
  「ゲスト〈name〉さんが冒頭で軽く挨拶。メインが進行、ゲストは〈theme〉に詳しい専門家として話す。最後にメインがお礼」を制約に追加。
  ゲストの persona も `# 出演者` に含める。冒頭の正式紹介はリード文が担うので台本では繰り返さない。
- 締め曲・フル再生・pause・完全静寂は他コーナーと同じ。

## 5. 配線

- Core: `CornerFormat.guest` / `CornerContext.guest` / `DialogueScriptGenerator`（guest 引数）/
  `CornerEngine.prepare`（guest を cast 末尾、リード文の guest/theme 置換、guest フレーミング）。
- Core `ProgramBlueprint.guestCornerId` + `ProgramPlan`（最初の news 直後にゲスト talk を挿入、index/total を +1）。
- Core `BroadcastEngine`: `run(..., guests: [DjProfile])`。放送開始時にプールから 1 名選定（乱数注入）。
  `cornerContext` で `segment.cornerId == guestCornerId` のとき `context.guest = 選定ゲスト`（greeting nil・leadIn = guest コーナーの lead_in）。
  fail-fast: guestCornerId 設定時、guest コーナー template 不在 / プール空 / レギュラー衝突。
- Infra: `GuestsConfigLoader`（新規）。`CornersConfigLoader` は guest コーナー（format: guest）をそのまま読む。
- App `BroadcastWiring`: `guests.yaml` を読み `engine.run(..., guests:)` に渡す。`MenuBar` 変更なし。
- program.yaml: `guest:\n  corner_id: guest` を追加。

## 6. テスト

- `GuestsConfigLoader`: 読み込み・必須欠落・（衝突検出は engine 側）。
- `ProgramPlan`: guestCornerId 設定で N=2/4/エンドレスに最初の news 直後 1 個だけ guest 挿入、2 回目 news 後は無し、
  N≤1 は無し、totalSegmentCount +1、N（トーク数）に数えない。
- `BroadcastEngine`: ゲストを乱数でプールから選定（決定論）、guest セグメントの準備に context.guest が渡る、
  fail-fast（プール空 / 衝突）、1 放送ちょうど 1 回。
- `CornerEngine`（format: guest）: cast 末尾にゲスト、リード文の {guest}/{theme} 置換（時刻は run 時展開）、
  台本プロンプトにゲスト挨拶・お礼・専門家・テーマ、選曲・締め曲・pause。
- `DialogueScriptGenerator`: guest 非 nil で専門家フレーミング、nil で従来どおり。
- 既存保証（完全静寂・ローリング準備・ED ボタン・時報リード文の時刻正確性・S13.5 曜日替わり）は不変。

## 7. 受け入れ条件

- `swift build` / `swift test` 全グリーン。
- 放送中、**最初のニュースの直後に 1 回だけ**ゲストコーナーが入り、「{時刻}になりました。次はゲストコーナーです。
  本日は〈ゲスト〉さんを迎えて、〈テーマ〉について熱く語ってもらいます」で始まり、全員で会話（ゲストは専門家役）→
  お礼 → 曲、の流れになる（ユーザー確認）。
- ゲストはレギュラー以外から選ばれ、声（speaker）も切り替わる。あんこもんは語尾「もん」で話す（ユーザー確認）。
- ゲストコーナーは 1 放送に 1 回だけ（2 回目以降のニュース後には入らない）（ユーザー確認）。
- エラーコード追加なし。

## 8. スコープ外（将来 / S15）

- アーティスト特集（S15）。
- ゲストのテーマ連動選定（タグマッチング等）— 今回は「ランダム選定＋専門家フレーミング」で代替。
- ゲストの感情スタイル（VOICEVOX style 切替）— 今回はノーマル固定。
