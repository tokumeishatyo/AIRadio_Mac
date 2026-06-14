# S19a — 読み正確化①：VOICEVOX ユーザー辞書の冪等同期（コア）

> 仕様駆動ワークフロー（CLAUDE.md §7）の SoT。**実装前にユーザーレビューを受ける**（§13 の設計判断・確定事項を要確認）。
> 要件定義 §（読み正確化）の採用分の**前半**。アーティスト読みの自動登録は **S19b**（別スライス）に分割（§12）。
> 参照: `s18-station-journal.md`（fail-tolerant 配線の前例）, `../CLAUDE.md`。
> **実機検証根拠**: VOICEVOX **v0.25.2**（`http://127.0.0.1:50021`）で `/user_dict` API と辞書の効き方を実証済み（§4・§5・§11）。

## 1. 概要

固有名詞・難読語の**誤読を矯正**する。`config/pronunciations.yaml`（表記 → カタカナ読み ＋任意アクセント）を
**放送開始時に VOICEVOX のユーザー辞書 `/user_dict` へ冪等同期**する。VOICEVOX は登録済み表記を入力テキスト内で
**形態素解析で検出**すると、指定の読み・アクセントで発音する（辞書は VOICEVOX エンジンのグローバル状態）。

- ✅ 効く例（実機確認済み）: `栄光の架橋 → エイコウノカケハシ` / `お家 → オウチ` / `Mr.Children → ミスターチルドレン` / `Official髭男dism → オフィシャルヒゲダンディズム` / `BUMP → バンプ`。
- **全ひらがな化はしない**（カタカナ読み＋`accent_type` でピッチを保持。ひらがな化はアクセント情報を失い棒読みになる）。
- 既存の文字レベル正規化 `VoicevoxTTS.normalizeForSpeech`（波ダッシュ／全角チルダ → 長音）と**役割分担**:
  正規化＝文字単位の置換（合成のたびにテキストを munge）／辞書＝語単位の読み・アクセント矯正（VOICEVOX 側の状態）。両者は補完関係。

### 1.1 既知の制約（実機確定・仕様として明記）

VOICEVOX のユーザー辞書は**形態素解析で surface を照合**する。**空白を含む純英字の surface は単一トークンとして照合されず、登録しても効かない**。

- ❌ 効かない: `SEKAI NO OWARI`（実機: 登録しても `エス・イー・ケー…` とアルファベットを1文字ずつ棒読み）、`BUMP OF CHICKEN` 等。
- ✅ 効く表記クラス: 日本語（`栄光の架橋`）、漢字交じり、**空白なし**英字単語（`BUMP`）、記号で結合した英字（`Mr.Children`・`Official髭男dism`）。
- **運用での回避（ユーザー判断 2026-06-14：今は割り切り）**: 空白英字名は**通称カナ**（`セカオワ`）や**空白を詰めた表記**を surface にする。
  根本対応（合成前のテキスト置換層）は将来の検討課題として §12 にメモ（今スライス対象外）。

## 2. データモデル（Core）

`ArtistProfile`（`Sources/AIRadioCore/ArtistFeature.swift`）に倣い、ドメイン型は **Core**・ローダ／同期実装は **Infra**。

```swift
// Sources/AIRadioCore/Pronunciation.swift
public struct PronunciationEntry: Sendable, Equatable {
    public let surface: String        // 表記（入力テキストにこの語が現れたら読みを差し替える）
    public let pronunciation: String  // 読み（全角カタカナ。§4 の制約参照）
    public let accentType: Int        // アクセント型（音が下がるモーラ位置。0 = 平板。既定 0）
    public let wordType: String?      // 任意。PROPER_NOUN / COMMON_NOUN / VERB / ADJECTIVE / SUFFIX
    public let priority: Int?         // 任意。0–10（大きいほど優先・未指定時サーバ既定 5）
    public init(surface: String, pronunciation: String,
                accentType: Int = 0, wordType: String? = nil, priority: Int? = nil) { ... }
}
```

- `accentType` の既定は **0**（ユーザー判断 2026-06-14）。**API では必須**なので、yaml 未指定でもクライアントが常に 0 を送る（§4）。
- `pronunciation` は **全角カタカナ必須**（ひらがな・半角カナは VOICEVOX が 422 で弾く。§4・§5 で送信前に正規化／検証）。

## 3. 設定ファイル（`config/pronunciations.yaml`）

```yaml
# 読み正確化（仕様 s19a）。表記 → カタカナ読み。放送開始時に VOICEVOX /user_dict へ冪等同期する。
# 読みは全角カタカナで書く（ひらがな・半角カナは登録不可）。accent_type: 0=平板（既定）。
# 注意: 空白を含む純英字の表記（SEKAI NO OWARI 等）は VOICEVOX が照合できず効かない（§1.1）。
#       その場合は通称カナ（セカオワ）など空白なしの表記を surface にする。
pronunciations:
  - surface: "栄光の架橋"
    pronunciation: "エイコウノカケハシ"
  - surface: "お家"
    pronunciation: "オウチ"
  - surface: "Mr.Children"
    pronunciation: "ミスターチルドレン"
```

- 命名規約（CLAUDE.md §3-4）: kebab-case ファイル / snake_case キー。機密ではないので `.local` ではなく**コミット対象**（サンプル兼デフォルト辞書）。
- **手編集前提**。行を足せば次の放送から反映（既存「YAML は放送のたびに読み直す」方針と整合）。
- **出荷デフォルトに入れるのは実機で効くと確認済みのエントリのみ**（§1.1 の効く表記クラス）。**空白英字名は入れない**。各エントリの実機検証を完了条件に含める。
- `artists.yaml` は出荷時空・このファイルだけがデフォルト辞書を持つ。

## 4. VOICEVOX 辞書 API（実機 v0.25.2 確定）

| 操作 | メソッド・パス | パラメータ | 備考 |
|---|---|---|---|
| 取得 | `GET /user_dict` | なし | 応答 = `{ uuid文字列: UserDictWord }`。初期 `{}`。正常時 200（空でも `{}`） |
| 追加 | `POST /user_dict_word` | **クエリ**: `surface`✱ / `pronunciation`✱ / `accent_type`(int)✱ / `word_type`? / `priority`(0–10)? | **body=nil**。成功 **200**、応答 = 生成 UUID（`"..."` 二重引用符付き文字列） |
| 更新 | `PUT /user_dict_word/{uuid}` | path: `uuid`✱ ＋ 追加と同じクエリ | uuid 不在は **422**（404 ではない） |
| 削除 | `DELETE /user_dict_word/{uuid}` | path: `uuid`✱ | **本スライスでは使わない**（§6） |

✱ = **API 必須**。重要な実機事実（仕様の前提）:

1. **登録はクエリパラメータ方式**（JSON body ではない。`audio_query` と同じ「クエリのみ・body=nil の POST」流儀）。日本語値は URL エンコード必須（`URLComponents`/`URLQueryItem` が処理）。
2. **`accent_type` はサーバ必須・既定なし** → yaml 未指定時もクライアントが**常に 0 を送る**（送らないと 422）。`accent_type=0`（平板）は実機で常に妥当（範囲 0..モーラ数）。
3. **`pronunciation` は全角カタカナ限定** → ひらがな・**半角カナ**は 422（「発音は有効なカタカナでなくてはいけません」）。送信前に NFKC で全角カタカナへ正規化＋カタカナ検証（§5）。全角カタカナは入力どおり round-trip して返る（＝読み比較が安定・PUT 無限ループの懸念なし）。
4. **サーバが `surface` を全角に正規化して保存・返却する** → `Mr.Children` は GET で `Ｍｒ．Ｃｈｉｌｄｒｅｎ`（英字は全角・空白は半角のまま）。**raw 文字列での突合は不可**。突合は NFKC 正規化後の surface で行う（§5）。
5. `priority` 未指定時のサーバ既定は **5**。`word_type` 未指定は part_of_speech=名詞 として登録。**差分判定には priority/word_type を含めない**（含めると既定 5 とのズレで誤 PUT が起きる）。
6. POST 応答 UUID（二重引用符付き）は**本スライスでは未使用**（PUT 対象 uuid は GET から取る）。将来使うなら JSONDecoder で String デコード。

## 5. 辞書同期（Infra）

```swift
// Sources/AIRadioInfra/VoicevoxUserDict.swift
public struct VoicevoxUserDict {
    private let base: URL
    private let http: any HTTPClient   // BroadcastWiring の URLSessionHTTPClient を共有（VoicevoxTTS と同様）
    public init(endpoint: String, http: any HTTPClient) { /* VoicevoxTTS と同じ base パース */ }

    /// 冪等同期：表記が無ければ追加・読み/アクセントが違えば更新・同一なら何もしない。削除はしない。
    /// **完全 fail-tolerant：throw しない**（VOICEVOX 未起動・個別 422 でも放送を止めない）。
    public func sync(entries: [PronunciationEntry]) async -> PronunciationSyncSummary
}

public struct PronunciationSyncSummary: Sendable, Equatable {
    public var added = 0, updated = 0, skipped = 0, failed = 0
    public var unreachable = false
}
```

### 5.1 正規化（実機の癖を吸収。突合・冪等の要）

- **突合キー** `matchKey(surface) = NFKC(surface)`。config の raw surface と GET 返却の全角 surface を**両辺とも NFKC**して比較する（`Mr.Children` ↔ `Ｍｒ．Ｃｈｉｌｅｄ…` を一致させる）。これが無いと英字エントリが毎回 POST されて二重登録になる（§4-4）。
- **読みの正規化** `normalizePron(pron) = NFKC(pron)`（半角カナ → 全角カナ）。さらに**カタカナ検証**（カタカナ U+30A1–U+30FA ＋ 長音 `ー` ＋ 中黒 `・` のみ許容）。**非カタカナ（ひらがな・漢字・英字等）を含むエントリは送信せずスキップ**し `failed++`＋`E-PRON-WORD-REJECTED-001` をログ（422 を取りに行かない）。
- **config 内の重複**は `matchKey` で先勝ち排除（表記ゆれ `Mr.Children` / `Ｍｒ．…` の二重処理を防ぐ）。

### 5.2 同期アルゴリズム（冪等・no-throw）

1. `GET /user_dict` → `[uuid: ExistingWord]` をデコード（`ExistingWord { surface; pronunciation; accentType }`、`accent_type` を CodingKeys で対応）。
   - **GET が失敗したら（`URLError` / `HTTPClientError.status` / その他いずれも全捕捉）** `unreachable = true` にして即 return（`E-PRON-SYNC-UNREACHABLE-001` をログ・**放送は継続**）。
2. `matchKey(GET surface) → (uuid, NFKC(pronunciation), accentType)` のマップを構築。
3. 各 `entry`（5.1 の読み検証を通したもの）について:
   - **`if Task.isCancelled { return summary }`**（throw しない cancellation 観測。停止後は外部 I/O を即休止＝CLAUDE.md §3-1 を sync 区間でも満たす）。
   - `key = matchKey(entry.surface)`、`existing = map[key]`、`pron = normalizePron(entry.pronunciation)`。
   - 既存に無い → `POST /user_dict_word`（クエリに surface/pronunciation(=pron)/accent_type［＋ word_type/priority があれば］、body=nil）→ `added++`。
   - 既存にあり **`existing.pronunciation != pron` または `existing.accentType != entry.accentType`** → `PUT /user_dict_word/{uuid}`（同クエリ）→ `updated++`。
   - 既存にあり、読みもアクセントも同一 → **何もしない** → `skipped++`。
   - 個別の POST/PUT 失敗は **全捕捉**（`HTTPClientError.status(422)` / `URLError` / その他）→ そのエントリのみ `failed++`＋`E-PRON-WORD-REJECTED-001` ログ、**ループは継続**（throw しない）。
4. `PronunciationSyncSummary` を返す（呼び出し側がログ）。

- **再実行で何も起きない**（同一なら skip）＝真に冪等。**手動登録分は触らない**（自分の config に無い surface は無視）。
- 比較は **pronunciation と accent_type のみ**（§4-5）。
- 登録/更新は逐次。初回（手編集で増やした直後）は N 件の POST が走るが、ローカル HTTP かつ「放送開始前の無音は許容」原則で許容範囲。冪等が効けば再放送時は skip のみで無音増分ほぼゼロ（将来 `parallel` 化の余地）。
- **TOCTOU 補足**: GET→個別 POST/PUT の read-modify-write なので、外部から同じ辞書を同時編集すれば競合し得るが、本アプリは多重放送を `BroadcastSession` が拒否（`state == .idle` ガード）するため非問題。

## 6. 削除しない設計（HTTPClient に DELETE が無い／要件とも一致）

- 既存 `HTTPClient`（get/post/put のみ）を拡張しない。同期は**追加・更新のみ・削除なし**。
- これは「**ユーザー手動登録分を触らない**」要件と一致する正しい意味論。
- **既知の割り切り**: `pronunciations.yaml` から行を消しても、すでに VOICEVOX に載った読みは残る。
  surface を書き換えた場合（例: 効かない `SEKAI NO OWARI` → 効く `セカオワ`）、**旧エントリは VOICEVOX 側に残留**する。
  気になる場合は **VOICEVOX のユーザー辞書画面で削除**する（運用導線）。将来 DELETE 対応するなら `HTTPClient` に delete を足す（本スライス対象外）。

## 7. 配線

- `makeBroadcastStack`（`BroadcastWiring.swift:65`、`throws`・**非 async**）で:
  - `config/pronunciations.yaml` をロード（無ければ空＝同期なし。壊れていれば throw＝fail-fast、`guests.yaml`/`calendar.yaml` と同じ `fileExists` 分岐）。
  - `let userDict = VoicevoxUserDict(endpoint: ttsConfig.endpoint, http: http)`（`tts` と同じ `http`・endpoint を共有）。
  - `userDict` と `[PronunciationEntry]` を `BroadcastStack` に保持。
- `BroadcastStack.run()`（**async throws**。呼び出しは `MenuBar.swift:183`〔本番メニュー〕と `main.swift:330`〔broadcast デモ〕）の**冒頭**で:
  - `let summary = await userDict.sync(entries:)` → サマリをログ → 既存の `try await engine.run(...)`。
  - **本番もデモも `run()` 経由なので両放送経路をカバー**。単機能デモ（`AIRADIO_DEMO=tts`/`corner`/`theme`）は `run()` を通らず同期しない（開発用ツールのため許容）。
- **完全 fail-tolerant**: `sync` は throw しない。VOICEVOX 未起動でも `unreachable` で続行（合成時に既存の `E-TTS-UNREACHABLE-001` が出る）。

## 8. エラーコード（新カテゴリ PRON）

`error-codes.md` と CLAUDE.md §4-3 のカテゴリ列挙に `PRON` を追加。**ART/JNL と同じく診断ログ用・throw しない**（同期は fail-tolerant）。
設定ファイルの破損・必須欠落は従来どおり CFG（`E-CFG-MISSING-FIELD-001`、fail-fast）。

| コード | カテゴリ | 発生条件 | 導入 |
|---|---|---|---|
| `E-PRON-SYNC-UNREACHABLE-001` | PRON | VOICEVOX に接続できず辞書同期できない（GET 失敗。ログのみ・放送継続） | S19a |
| `E-PRON-WORD-REJECTED-001` | PRON | 個別エントリの登録/更新が拒否（422 等）または読みが非カタカナ → そのエントリのみスキップ（ログのみ） | S19a |

## 9. テスト（`swift test` グリーンが完了条件）

`FakeHTTPClient`（`init(responder: @Sendable (URL) throws -> Data)`、`requests` 記録。既存 `Tests/AIRadioInfraTests/Helpers/FakeHTTPClient` を流用）で決定論検証。`url.path.contains("user_dict")` でエンドポイント分岐。

- **`PronunciationsConfigLoader`**: surface/pronunciation/accent_type/word_type/priority をパース／`accent_type` 欠落で既定 0／ファイル無しで空／空・コメントのみで空／壊れで `ConfigError.missingField` throw。
- **`VoicevoxUserDict.sync`**:
  - 空辞書＋2件 → `POST /user_dict_word` が 2 回、クエリに surface/pronunciation/accent_type（URL エンコード）が載る。`accent_type` は未指定でも 0 が載る。
  - **正規化突合（冪等の核）**: GET が全角 surface（`Ｍｒ．Ｃｈｉｌｄｒｅｎ`）＋全角カタカナ読みを返し、config が半角 surface（`Mr.Children`）＋同一読み → **POST も PUT も呼ばれず `skipped`**。
  - 既存と読み違い → その uuid へ `PUT`（`updated`）。priority だけ違っても PUT しない（比較対象外）。
  - **半角カナ読み**（`ﾐｽﾀｰﾁﾙﾄﾞﾚﾝ`）→ NFKC で全角化して POST のクエリに全角カタカナが載る。**ひらがな読み**（`みすたー`）→ 送信されず `failed`（`E-PRON-WORD-REJECTED-001`）。
  - 個別 `422`／`URLError`／その他 → そのエントリのみ `failed`、他は処理継続、**sync は throw しない**。
  - `GET /user_dict` が `URLError` → `unreachable = true`・以降の書き込みなし。`GET` が `HTTPClientError.status(500)` → 同じく `unreachable`。
  - `word_type`/`priority` は指定時のみクエリに載る／未指定なら載らない。
  - cancellation: 同期前に Task をキャンセル → 書き込みが発生しない（`requests` が空、`Task.isCancelled` 観測）。
- **配線**: `pronunciations.yaml` 無しで sync 入力が空・放送は通常進行（既存テストに無影響）。

## 10. 受け入れ基準（ライブ確認・表記クラス別）

1. **日本語/和語が効く**: `栄光の架橋 → エイコウノカケハシ`、`お家 → オウチ` を入れて放送 → 正しい読みで発音。
2. **記号交じり英字が効く**: `Mr.Children → ミスターチルドレン` が正しく発音。
3. **空白純英字は効かない＝仕様**: `SEKAI NO OWARI` は登録しても効かない（§1.1）。これを**バグでなく既知制約**として確認し、通称カナ運用で回避できることを確認。
4. **冪等**: 同じ語で再放送 → 二重登録されない（`GET /user_dict` のエントリ数が増えない）。※同一プロセス内・外部から辞書を触らない条件で。
5. **VOICEVOX 落ち**: VOICEVOX を止めて放送開始 → 辞書同期は失敗ログのみで、放送自体は通常どおり進む（その後 VOICEVOX を上げれば合成は復帰）。
6. **削除しない割り切り**: `pronunciations.yaml` から行を消しても、その回は読みが残る（§6）。

## 11. スコープ外（S19a）

- **アーティスト読みの自動登録 → S19b**（§12）。
- 辞書エントリの削除・全置換（`import_user_dict`）。`HTTPClient` への DELETE 追加。
- 合成前テキスト置換層（空白英字名の根本対応。§12 にメモ）。
- 単機能デモ（tts/corner/theme）への辞書同期。アクセント自動推定。読みの自動学習。複数 VOICEVOX エンジン対応。

## 12. S19b（次スライス）への申し送り — アーティスト読み自動登録

ユーザー判断（2026-06-14）でスコープには含むが、**実装は別スライス**（破壊的変更＋別軸検証のため）。S19b で専用 spec を起こす。設計メモ:

- **Core**: `ArtistProfile`（`Sources/AIRadioCore/ArtistFeature.swift`、id/name は既に `var`）に `reading: String?`（既定 nil・後方互換）を追加。s15 が将来拡張として記載済み（s15 §16/§17-3）。
- **Infra**: `ArtistsConfig.File.Artist` に `reading: String?`／`ArtistListGenerator` の出力契約変更（名前のみ → `アーティスト名<TAB>カタカナ読み`）。
  - **parseEntries の逸脱耐性を仕様化（必須）**: ①タブ無し行は「名前のみ・reading=nil」で必ず救済（既存の名前生成を退行させない）②最初のタブのみで2分割・以降無視 ③reading が非カタカナ（ひらがな/漢字/英字/「不明」等）なら nil 扱いで捨てる（VOICEVOX へ投げる前に。§5.1 のカタカナ検証を流用）。
- **辞書反映**: `artists.yaml` の `reading` を §5 の同期に合流（`mergedEntries(pronunciations:artists:)`、pronunciations.yaml が surface 衝突で優先）。
- **空白英字バンド名の壁**: §1.1 の制約により `SEKAI NO OWARI` 等の自動登録は効かない。S19b では「今は割り切り・通称カナ運用」を踏襲。根本対応として**合成前テキスト置換層**（`normalizeForSpeech` の語単位拡張。形態素照合を経由せず文字列置換で全表記に効くが、部分一致の過剰置換リスクあり＝`お家`→`お家芸` 誤爆等に注意）を S19b 以降の検討課題として残す。
- **破壊的変更の隔離**: S19b は既存「アーティスト一覧を生成」ボタンの挙動を変えるため、独立スライス＋独立ライブ確認で退行検証とロールバックを容易にする。

## 13. 設計判断（確定 — 2026-06-14 ユーザー承認）

- **A. スライス分割**: 本スライス S19a = **辞書同期コア**（手編集 `pronunciations.yaml`）。アーティスト読みは **S19b**（§12）。スコープ（最終的に同梱）は維持。
- **B. accent_type**: yaml では任意・**API では必須**。未指定はクライアント既定 **0** を常に送る。
- **C. 空白英字名**: VOICEVOX 辞書では効かない（実機確定）。**今は割り切り・通称カナ運用**。根本対応（テキスト置換層）は将来検討（§12）。
- **D. 同期タイミング**: **放送開始ごと**（`BroadcastStack.run()` 冒頭・冪等・fail-tolerant）。yaml 編集が次放送に反映。
- **E. 削除しない**: 追加・更新のみ（§6）。手動登録を保護。
- **F. PRON カテゴリ新設**: 同期は fail-tolerant・診断ログ用（§8）。設定破損は CFG。
