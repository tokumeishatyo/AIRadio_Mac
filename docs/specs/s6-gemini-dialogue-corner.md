# S6 — Gemini 台本生成 + DJ 二人の会話コーナー

## 1. 概要
LLM（Gemini API 無料枠）を統合し、**コーナーの基本パターン**を実装する:

> あるテーマについて **DJ 二人が 5 分程度の会話**をして、**最後に一曲音楽をかける**。

テーマは番組内の各コーナーで決める（設定駆動）。本スライスではコーナーテンプレートを 1 つ
（フリートーク）作り、`AIRADIO_DEMO=corner` で通しのライブ確認を行う。
LLM 不調時も放送を止めない fail-tolerant 設計（§7）。

## 2. スコープ

**in**:
- `GeminiLLMBackend`（Infra, `LLMBackend` 実装）: `generativelanguage.googleapis.com` の
  `models/{model}:generateContent` へ POST。systemInstruction / temperature 対応。
- `LlmConfig` + `LlmConfigLoader` + `config/llm.yaml`（モデル ID 等、非機密）+
  `config/llm.local.yaml`（**API キー、gitignore**）+ `config/llm.local.yaml.sample`
- **API キー誤コミット防止**（§8。pre-commit フック + サンプルファイル + ログマスク）
- DJ 定義 `config/djs.yaml`（名前 / VOICEVOX speaker id / 一人称・口調などのペルソナ）
- コーナーテンプレート `config/corners.yaml`（テンプレ 1 つ: `free_talk`）
- `DialogueScript` / `DialogueLine`（Core DTO）
- `DialogueScriptGenerator`（Core）: テンプレ + テーマ + DJ ペルソナ + 確定済み楽曲から
  プロンプトを組み立て、LLM 応答を台本にパース
- `SongPicker`（Core）: LLM に候補曲を挙げさせ、プレフライト（検索 + `isPlayable`）で 1 曲確定
- `CornerEngine`(Core): コーナー 1 本の進行（§4 パイプライン）。protocol 越しに全依存を注入
- App デモ: `AIRADIO_DEMO=corner`
- テスト: 台本パース / プロンプト構築 / SongPicker のプレフライトとフォールバック /
  CornerEngine の進行・キャンセル・後始末 / LlmConfigLoader（キー欠落 = fail-fast）/
  GeminiLLMBackend（FakeHTTPClient でリクエスト形状・応答抽出）

**out（後続）**:
- 番組全体の進行（13 コーナー構成・放送エンジン）→ 後続スライス
- ニュース・天気の LLM 会話化（本パターンの theme に S5 データを流し込む）→ 後続
- ステーション・ジャーナル（長期記憶）/ お便り → 後続
- Gemma フォールバックモデルの自動切替（設定でモデル差し替えは可能にしておく）→ 後続

## 3. LLM（Gemini）

- エンドポイント: `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`
  認証はヘッダ `x-goog-api-key: <API キー>`（URL クエリ `?key=` は使わない。ログ・エラーに URL が
  出ても安全なように）。
- モデル ID は実装時に `GET /v1beta/models` で**実在確認してから** `config/llm.yaml` に確定値を書く
  （想定: Gemini 3.1 Flash Lite 系。無料枠）。モデルは設定値であり、コードにハードコードしない。
- `LLMRequest.system` → `systemInstruction`、`temperature` → `generationConfig.temperature`。
- 応答は `candidates[0].content.parts[].text` を連結。空なら `E-LLM-EMPTY-RESPONSE-001`。

## 4. コーナーの進行（CornerEngine パイプライン）

1. **選曲（プレフライト先行）**: `SongPicker` が LLM にテーマに合う候補曲を最大 5 つ
   挙げさせる（`曲名 - アーティスト` 形式 1 行 1 曲）→ 順に `TrackSearcher` で検索し
   最初の再生可能曲で確定。全滅ならテンプレの `fallback_track_uri` を使う。
   **曲紹介テキストの生成より前に再生可否を確定**する（CLAUDE.md §3-2）。
2. **台本生成**: `DialogueScriptGenerator` が確定済みの曲名・アーティストをプロンプトに含めて
   LLM を 1 回呼び、二人の会話台本を生成。会話の最後で自然にその曲を紹介して締める。
3. **発話**: 台本を 1 行ずつ、その行の DJ の speaker id で TTS 合成 → 再生（直列）。
4. **一曲**: 確定した曲を Web API で再生（テンプレの `volume`）。`play_seconds` 秒経過後
   フェード等はせずそのまま `pause`（曲をフルでかけるかは設定値、§5）。
5. **後始末**: 正常・例外・キャンセルいずれでも `defer` で `pause()`（完全静寂、CLAUDE.md §3-1）。
   各 await 点で `CancellationError` を伝播。

### 台本フォーマット（LLM 出力契約）
- 1 行 = `DJ名: セリフ`。登録 DJ 名で始まらない行（空行・マークダウン飾り等）は無視する。
- パース結果が 4 行未満なら `E-LLM-SCRIPT-PARSE-FAILED-001`。
- 5 分程度 = **文字数で制御**: `target_minutes × chars_per_minute`（既定 320 字/分 → 約 1600 字）を
  プロンプトで指示。LLM の長さ制御は不正確なため受け入れは「おおむね 4〜6 分」とする。

## 5. 設定ファイル

```yaml
# config/llm.yaml（コミット対象・非機密）
llm:
  provider: gemini
  model: "<実在確認したモデル ID>"
  endpoint: "https://generativelanguage.googleapis.com/"
  temperature: 0.9

# config/llm.local.yaml（gitignore。サンプルは llm.local.yaml.sample）
llm:
  api_key: "AIza..."

# config/djs.yaml
djs:
  - id: zundamon
    name: "ずんだもん"
    speaker_id: 3            # 実装時に /speakers で実在確認
    persona: "一人称はボク。語尾は「〜なのだ」。好奇心旺盛で明るい。"
  - id: metan
    name: "四国めたん"
    speaker_id: 2
    persona: "一人称はわたくし。上品で落ち着いた口調。ツッコミ役。"

# config/corners.yaml（テンプレート 1 つ）
corners:
  - id: free_talk
    title: "フリートーク"
    theme: "最近ちょっと気になっていること"   # コーナーごとにここを差し替える
    dj_ids: [zundamon, metan]
    target_minutes: 5
    chars_per_minute: 320
    song_prompt_hint: "テーマの余韻に合う、よく知られた邦楽・洋楽"
    fallback_track_uri: "spotify:track:5jsqaNOAbeBG5QYL7JpySJ"
    volume: 85
    play_seconds: 60          # デモでは 1 曲フルではなく頭出し再生。0 = フル再生
```

## 6. エラーコード（追記）
| コード | 発生条件 | 扱い |
|---|---|---|
| `E-LLM-KEY-MISSING-001` | `llm.local.yaml` がない / api_key 空 | fail-fast（起動時） |
| `E-LLM-API-FAILED-001` | generateContent が非 2xx / 通信失敗 | fail-tolerant |
| `E-LLM-EMPTY-RESPONSE-001` | 応答にテキストがない | fail-tolerant |
| `E-LLM-SCRIPT-PARSE-FAILED-001` | 台本パース結果が 4 行未満 | fail-tolerant |

fail-tolerant の意味: コーナー実行は中断するが**必ず `pause()` で静寂に戻し**、エラーはログのみ。
（番組全体への組み込み後は「コーナースキップで放送継続」になる。S6 デモではエラー表示して終了。）

## 7. API キーの誤コミット防止（ヒューマンエラー対策）

多層防御。**どれか 1 つが破られても残りで止める**:

1. **gitignore（既存）**: `config/*.local.yaml` は除外済み。
2. **pre-commit フック（新規・コミット対象）**: `scripts/git-hooks/pre-commit` を追加し、
   `git config core.hooksPath scripts/git-hooks` で有効化（実装時に設定 + HANDOVER に記載）。
   以下のいずれかでコミットを**拒否**する:
   - ステージに `*.local.yaml` が含まれる（`--force` で gitignore を突破した場合を捕捉）
   - ステージ内容に Google API キーパターン `AIza[0-9A-Za-z_-]{35}` がマッチ
     （ソースやドキュメントへのコピペ混入を捕捉）
3. **サンプルファイル運用**: コミットするのは `llm.local.yaml.sample`（プレースホルダのみ）。
   本物のキーはサンプルをコピーした `llm.local.yaml` にしか書かない。
4. **ログ・エラーのマスク**: キーは URL ではなくヘッダで送る（§3）。エラーメッセージ・ログに
   キー値を**絶対に含めない**（Loader はキーの有無のみ報告）。
5. **検証をテスト化**: フックの拒否動作は受け入れ条件に含める（§8）。

## 8. 受け入れ条件
- `swift build` / `swift test` 全グリーン（LLM/HTTP は fake、ネットワーク非依存）
- 実機 `AIRADIO_DEMO=corner swift run AIRadioApp` で、テンプレのテーマについて
  ずんだもん・四国めたんの**二人の会話（おおむね 4〜6 分）→ 最後に実曲再生**が通る（ユーザー確認）
- 会話の締めで、実際に再生される曲（プレフライト済み）が自然に紹介されている
- 停止（Ctrl-C / キャンセル）・異常時に Spotify が必ず `pause` される
- **フック検証**: `config/llm.local.yaml` を `git add -f` してコミットを試みると**拒否される**こと、
  `AIza...` 形式の文字列を含むファイルのコミットが**拒否される**ことを実機確認
- `git log -p` に API キーが一切現れない

## 9. 必要なもの（ユーザー準備）
- **Gemini API キー**（Google AI Studio で無料発行）。実装の後半（ライブ確認の前）に必要。
  受け渡しは「`config/llm.local.yaml` にユーザー自身が書く」方式とし、チャットにキーを
  貼らなくてよい手順を案内する。
