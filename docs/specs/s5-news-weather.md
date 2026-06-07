# S5 — ニュースと天気予報（実データ: News RSS + 気象庁）

## 1. 概要
ニュースセグメントのダミー文言を、無料・APIキー不要の実データに置き換える。
ニュースは **Google News RSS**、天気は **気象庁 予報 API**。取得結果を定型テンプレートで組み立て、
ずんだもんが読み上げる。LLM による会話化は S6（今回は決定論的整形）。取得失敗は **fail-tolerant**。

## 2. スコープ

**in**:
- `NewsRssSource`（`ResearchSource`）: Google News RSS を取得し XMLParser で上位 N 見出しを抽出。
  Google の `見出し - メディア名` から末尾のメディア名を除去。
- `JmaWeatherSource`（`ResearchSource`）: 気象庁 `forecast/{area_code}.json` を取得し当日の天気文字列を抽出。
- `NewsWeatherProvider`: news / weather を fetch（fail-tolerant、try?）し `announcement_template` に展開して
  ニュース原稿を生成。
- `ResearchConfig` + `ResearchConfigLoader` + `config/research.yaml`
- `ResearchError`（NEWS / WX）
- App テーマデモ: ニュースセグメントの announcement を実データ生成に差し替え
- テスト: NewsRssSource（RSS パース・メディア名除去・チャンネルタイトル除外）/ JmaWeatherSource（JSON 抽出・全角空白正規化）/ NewsWeatherProvider（fail-tolerant・テンプレ展開）/ ResearchConfigLoader

**out（後続）**:
- LLM による会話的トーク化 → S6
- 専用 BGM とコーナー進行への完全統合（放送エンジン）→ 後続
- エリア自動判定 / 複数地域 → 後続（area_code は設定で固定）

## 3. データソース
- ニュース: `GET https://news.google.com/rss?hl=ja&gl=JP&ceid=JP:ja` → `<item><title>` 上位 N
- 天気: `GET https://www.jma.go.jp/bosai/forecast/data/forecast/{area_code}.json`
  → `[0].timeSeries[?].areas[area_name or 先頭].weathers[0]`（全角空白 `　` を除去）

## 4. 受け入れ条件
- `swift build` / `swift test` 全グリーン（fake HTTP でパース検証、ネットワーク非依存）
- 実機 `AIRADIO_DEMO=theme swift run AIRadioApp` で、ニュースセグメントが**実際の最新ニュース見出しと当日の天気**を読み上げる（ユーザー確認）

## 5. エラーコード（追記）
| コード | 発生条件 |
|---|---|
| `E-NEWS-FETCH-FAILED-001` | News RSS 取得・解析失敗 |
| `E-WX-FETCH-FAILED-001` | 気象庁 取得・解析失敗 |
（Provider は fail-tolerant でフォールバック文言に切替え、放送は継続）
