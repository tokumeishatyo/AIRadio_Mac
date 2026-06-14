# S19b — 読み正確化②：アーティスト読みの自動登録

> 仕様駆動ワークフロー（CLAUDE.md §7）の SoT。**実装前にユーザーレビューを受ける**（§10 の設計判断を要確認）。
> S19a（`s19a-pronunciation-dictionary.md`）の続き。S19a の辞書同期機構（`VoicevoxUserDict`）に、アーティスト名の読みを合流させる。
> 参照: `s19a-pronunciation-dictionary.md` §12（申し送り）, `s15-artist-feature.md`（`reading` を後方互換の将来拡張として記載済み §16/§17-3）。

## 1. 概要

「アーティスト一覧を生成」時に**各アーティストのカタカナ読みも LLM に併出させ** `config/artists.yaml` に保存し、
**S19a の辞書同期に合流**させる（アーティスト名が DJ の発話テキストに現れたら正しい読みで発音）。

- 例: `Mr.Children → ミスターチルドレン`、`Official髭男dism → オフィシャルヒゲダンディズム`、`米津玄師 → ヨネヅケンシ`。
- 効き方は S19a と同じ VOICEVOX ユーザー辞書経由。**空白を含む純英字バンド名（"SEKAI NO OWARI" / "BUMP OF CHICKEN"）は効かない**
  （S19a §1.1 の制約。形態素解析で照合されないため）→ **通称カナ運用で割り切り**（ユーザー判断 2026-06-14）。
- **破壊的変更**: 既存「アーティスト一覧を生成」ボタンの LLM 出力契約（名前のみ → 名前＋読み）を変える。独立スライス・独立ライブ確認。

## 2. データモデルの変更（Core）

`ArtistProfile`（`Sources/AIRadioCore/ArtistFeature.swift`）に**任意フィールド** `reading` を追加（**後方互換**）。

```swift
public struct ArtistProfile: Sendable, Equatable {
    public var id: String
    public var name: String
    public var reading: String?          // 追加: カタカナ読み（任意。nil = 読み未登録）
    public init(id: String, name: String, reading: String? = nil) { ... }
}
```

- 既定 `nil` ＝既存の `init(id:name:)` 呼び出し（ArtistListGenerator / ArtistsConfig / 各テスト）は無改修。Equatable 合成は reading=nil 同士で従来どおり一致。

## 3. 生成・保存・読込の変更（Infra）

### 3.1 `ArtistsConfig`（読込）
`File.Artist` に `let reading: String?` を追加 → `ArtistProfile(id:, name:, reading: artist.reading)`。任意なので欠落許容（**既存 artists.yaml はそのまま読める**）。

### 3.2 `ArtistListGenerator`（生成）
- **プロンプト**（`makeRequest`）: 出力を「`アーティスト名<TAB>カタカナ読み`」の 2 列に変更。読み不明なら名前のみ可。例を 1 行示す。読みは**全角カタカナ**で、と明示。
- **パース**（`parseNames` → `parseEntries`）: 1 行を**最初のタブ**で 2 分割し `(name, reading?)` を返す（§3.3 の逸脱耐性）。
- **検証・採用**（`generate`）: 従来どおり `name` で Spotify 実在検証（`topTracks`）・`canonicalName` 去重。採用時に `reading` を保持し `ArtistProfile(id:, name:, reading:)` を作る。
- **書き出し**（`write`）: `Out.A` に `reading: String?` を追加。**nil のときはキーを出力しない**（`encode(to:)` を手書きして `reading` 非 nil のときだけ encode＝artists.yaml を汚さない）。

### 3.3 `parseEntries` の逸脱耐性（**仕様・必須**。LLM は契約を破る前提で設計）
1 行ごとに（先頭の bullet/番号/引用符は従来どおり除去後）:
1. **タブ無し行**は `(name, nil)`＝**名前のみで救済**（＝既存の名前生成を退行させない。読みが付かないだけ）。
2. **最初のタブのみ**で分割。2 列目を読み候補とし、3 列目以降は無視。
3. 読み候補を **NFKC+NFC 正規化**（`VoicevoxUserDict.normalizePronunciation`、半角カナ→全角カナ）した上で**カタカナ検証**（`VoicevoxUserDict.isKatakana`）。
   **カタカナ以外（ひらがな・漢字・英字・「不明」等）を含むなら `reading = nil`** にして捨てる（VOICEVOX に投げて 422 を取りに行かない）。
4. `name` が空の行はスキップ。

## 4. 辞書への反映（Infra・S19a と結線）

`VoicevoxUserDict.mergedEntries(pronunciations:artists:)`（S19a §5 で計画済み）を実体化:

```swift
extension VoicevoxUserDict {
    /// pronunciations.yaml（明示・優先）＋ artists.yaml の reading を NFKC キーで重複排除して統合。
    static func mergedEntries(pronunciations: [PronunciationEntry], artists: [ArtistProfile]) -> [PronunciationEntry]
}
```
- `pronunciations` を先頭（明示指定が**最優先**）。`artists` のうち `reading != nil` を
  `PronunciationEntry(surface: name, pronunciation: reading!, accentType: 0, wordType: "PROPER_NOUN")` として追加。
- surface の重複は **matchKey（NFKC）先勝ち**＝pronunciations.yaml が勝つ。
- **配線**: `makeBroadcastStack` で、現在 `BroadcastStack.pronunciations` に渡している値を
  `VoicevoxUserDict.mergedEntries(pronunciations: pronunciations, artists: artists)` に差し替える（`artists` は既にロード済み）。同期タイミング・冪等・fail-tolerant は S19a のまま。

## 5. 後方互換・運用

- **既存 artists.yaml（読みなし）はそのまま動く**（reading=nil → 辞書に登録しないだけ）。
- ユーザーが生成済みの 100 組は**旧生成（読みなし）**なので、読みを付けるには**「アーティスト一覧を生成」を再実行**する（次の放送開始で読みが辞書へ）。
- 生成直後ではなく**次の放送開始で反映**（S19a と同じタイミング。生成直後同期は将来余地）。
- **空白英字バンド名は効かない**（S19a §1.1）。生成で読みは付くが辞書照合されない。割り切り（通称カナは手編集 pronunciations.yaml 側で対応可）。

## 6. エラー / fail-tolerant

- 読み生成は LLM 任せ＝不確実。**reading は完全に任意**（無くても名前のみで動く＝放送に無影響）。新エラーコードは増やさない。
- 非カタカナ読みは `parseEntries` で捨てる（VOICEVOX へ送る前）。辞書側の個別失敗は S19a の `E-PRON-WORD-REJECTED-001`（fail-tolerant）に集約。
- 生成全体の失敗（実在検証で全滅等）は従来の `ArtistGenError.noResults`（生成ツール固有・放送系外）。

## 7. テスト（`swift test` グリーンが完了条件）

- **`parseEntries`**（逸脱耐性が核）:
  - `"米津玄師\tヨネヅケンシ"` → `(米津玄師, ヨネヅケンシ)`。
  - `"あいみょん"`（タブ無し）→ `(あいみょん, nil)`（救済）。
  - bullet/番号付き `"- 1. サザンオールスターズ\tサザンオールスターズ"` → 名前・読みとも除去後に取得。
  - 半角カナ読み `"A\tｱｲﾐｮﾝ"` → `(A, アイミョン)`（正規化）。
  - 非カタカナ読み（ひらがな `"X\tえっくす"` / 漢字 / 英字 `"Y\tYomi"` / `"Z\t不明"`）→ reading=nil。
  - タブ複数 `"name\tヨミ\textra"` → `(name, ヨミ)`（2 列目のみ）。
  - 空名 `"\tヨミ"` → スキップ。
- **`ArtistsConfigLoader`**: `reading` ありで `ArtistProfile.reading` がセット／無しで nil（後方互換）。
- **`ArtistListGenerator.write`**: reading ありは `reading:` を出力・nil は出力しない（load 往復で確認）。
- **`ArtistListGenerator.generate`**（fake LLM/catalog）: 2 列出力をパースし reading 付き ArtistProfile を書く／タブ無し応答でも名前のみで生成継続（退行なし）。
- **`VoicevoxUserDict.mergedEntries`**: pronunciations 優先で artist reading を統合／surface 重複は pronunciations 勝ち／reading=nil の artist は対象外／artist 由来エントリは wordType=PROPER_NOUN。

## 8. 受け入れ基準（ライブ確認）

1. 「アーティスト一覧を生成」→ `config/artists.yaml` に `reading:` が併記される（日本語名・記号交じり英字名で）。
2. 生成後に放送開始 → 冒頭「📖 読み辞書同期」ログにアーティスト読みぶんの追加が出る。
3. アーティスト特集や通常トークでアーティスト名が**正しい読み**で発音される（例「Mr.Children＝ミスターチルドレン」）。
4. 空白純英字バンド名は効かない＝仕様（S19a §1.1）。
5. 既存（読みなし）artists.yaml でも従来どおり放送が回る（後方互換）。

## 9. スコープ外（S19b）

- 生成直後の即時辞書同期（次の放送開始で反映で足りる）。
- 空白英字名の根本対応（合成前テキスト置換層。S19a §12 の将来検討）。
- アクセント（`accent_type`）の自動推定（既定 0）。読みの手動上書き UI（手編集 artists.yaml / pronunciations.yaml で代替）。

## 10. 設計判断（要ユーザー確認 — レビューで確定）

- **A. 出力契約**: タブ区切り `名前<TAB>読み`。**タブ無しは名前のみで救済**（退行なし）。＊区切り文字はタブで確定でよいか。
- **B. 読み検証**: 非カタカナ読みは**捨てる**（nil 化）。VOICEVOX に投げない。＊この厳しめの方針でよいか。
- **C. 反映タイミング**: 次の放送開始（生成直後同期はしない）。＊S19a と揃える方針でよいか。
- **D. 空白英字名**: 割り切り（S19a 踏襲）。＊確認。
