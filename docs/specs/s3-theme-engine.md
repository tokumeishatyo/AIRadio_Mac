# S3 — 統一テーマ/BGM エンジン（OP / ニュース / ED）

## 1. 概要
方針.md の核心。OP・ニュースと天気・ED が共有する単一の `ThemeSequencer` を Core に実装する。
S1（VOICEVOX 音声）と S2（Spotify 制御）を組み合わせ、テーマ曲（BGM）をダッキングしながら
DJ の発話を重ねる演出を実現する。本スライスではニュース原稿はダミー文言（実データ取得は S5）。

## 2. 統一シーケンス
```
(tagline を喋る・任意) →
BGM 再生・フル音量(volume) → intro_seconds 待つ（裏で発話を先行 TTS 合成） →
ducked_volume へ降下 → 発話を再生 →
曲の「残り outro_seconds 秒」へシーク（位置 = 曲長 - outro_seconds）→ フル音量(volume) に戻す →
outro_seconds 待つ（曲の自然な終わりに着く）→ 停止
```
- OP: tagline「{DJ}の ケイラボAIラジオ」/ ニュース: tagline「ニュースと天気予報です」/ ED: tagline なし（いきなり BGM）。
- 完全静寂（CLAUDE.md §3-1）: 正常終了・例外・キャンセルいずれも最後に必ず `pause`。

## 3. スコープ

**in**:
- `ThemeConfig`（Core）: tagline? / trackUri / introSeconds / volume / duckedVolume / outroSeconds（曲末尾で流す秒数）
- `SpotifyController.currentTrackDurationSeconds()`（曲長取得、シーク位置計算に使用。Windows OpeningSequencer 踏襲）
- `ThemeSequencing` protocol + `ThemeSequencer`（Core）: TTS / AudioPlayer / SpotifyController / Clock を注入
- `SpotifyURI`（Core）: 共有 URL / spotify:track: / 裸 ID → `spotify:track:<ID>` 正規化
- `ThemeConfigLoader`（Infra, Yams）: `config/themes.yaml` の opening / news / ending を読み込み（track_uri 正規化、数値はデフォルト補完）
- `config/themes.yaml`（BGM URI と各 announcement。デフォルトは動作確認用に再生実績のある曲）
- `AIRadioApp` デモ（`AIRADIO_DEMO=theme`）: OP → ニュース → ED を順に演出
- テスト: ThemeSequencer（呼び出し順 / tagline 有無 / 完全静寂）/ SpotifyURI / ThemeConfigLoader

**out（後続）**:
- ニュース・天気の実データ（RSS / 気象庁）→ S5
- コーナー進行・コーナー間曲 → S4
- LLM 台本（ED 締めの動的生成）→ S6

## 4. 受け入れ条件
- `swift build` / `swift test` 全グリーン（外部非依存、fake で検証）
- 実機 `AIRADIO_DEMO=theme swift run AIRadioApp` で、OP/ニュース/ED それぞれ
  「tagline → BGM → ダッキング下で DJ 発話 → フル音量に戻りシーク → 余韻 → 停止」が聞こえる（ユーザー確認）

## 5. エラーコード
新規なし（`E-CFG-MISSING-FIELD-001` を themes.yaml の track_uri / セクション欠落に流用）。
