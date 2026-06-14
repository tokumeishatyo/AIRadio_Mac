import Foundation
import AIRadioCore

/// 読み辞書同期の結果サマリ（呼び出し側がログに出す。仕様 s19a §5）。
public struct PronunciationSyncSummary: Sendable, Equatable {
    public var added: Int = 0
    public var updated: Int = 0
    public var skipped: Int = 0
    public var failed: Int = 0
    /// VOICEVOX に接続できず（or 応答が壊れて）同期できなかった。
    public var unreachable: Bool = false
    public init() {}
}

/// VOICEVOX のユーザー辞書 `/user_dict` へ読みを**冪等同期**する（仕様 s19a）。
/// 表記が無ければ追加・読み/アクセントが違えば更新・同一なら何もしない。**削除はしない**（手動登録を保護）。
/// **完全 fail-tolerant：throw しない**（VOICEVOX 未起動・個別 422 でも放送を止めない）。
public struct VoicevoxUserDict: Sendable {
    private let base: URL
    private let http: any HTTPClient

    public init(endpoint: String, http: any HTTPClient) {
        self.base = URL(string: endpoint) ?? URL(string: "http://127.0.0.1:50021/")!
        self.http = http
    }

    /// `GET /user_dict` の 1 ワード（必要なフィールドのみ。他は無視）。
    private struct ExistingWord: Decodable {
        let surface: String
        let pronunciation: String
        let accentType: Int
        enum CodingKeys: String, CodingKey {
            case surface, pronunciation
            case accentType = "accent_type"
        }
    }

    /// 読み辞書を冪等同期する。
    public func sync(entries: [PronunciationEntry]) async -> PronunciationSyncSummary {
        var summary = PronunciationSyncSummary()
        guard !entries.isEmpty else { return summary }

        // 1) 既存辞書を取得。GET の失敗（接続不可・非2xx・応答破損）はいずれも unreachable で打ち切り（throw しない）。
        let existing: [String: ExistingWord]
        do {
            let data = try await http.get(url: makeURL("user_dict", []), headers: [:])
            existing = try JSONDecoder().decode([String: ExistingWord].self, from: data)
        } catch {
            summary.unreachable = true   // E-PRON-SYNC-UNREACHABLE-001（呼び出し側がログ）。
            return summary
        }

        // 2) surface（NFKC 正規化）→ (uuid, 既存ワード) のマップ。
        //    VOICEVOX は surface を全角化して保存・返却するため、raw 比較では一致しない（§4-4）。
        var bySurface: [String: (uuid: String, word: ExistingWord)] = [:]
        for (uuid, word) in existing {
            bySurface[Self.matchKey(word.surface)] = (uuid, word)
        }

        // 3) config 側を NFKC キーで重複排除しつつ差分適用。
        var seen = Set<String>()
        for entry in entries {
            // 停止後は外部 I/O を即休止（CLAUDE.md §3-1。throw しない cancellation 観測）。
            if Task.isCancelled { return summary }

            let key = Self.matchKey(entry.surface)
            guard seen.insert(key).inserted else { continue }   // 表記ゆれの二重処理を防ぐ。

            // 読みは全角カタカナへ正規化＋検証。非カタカナ（ひらがな/漢字/英字等）は送らずスキップ。
            let pron = Self.normalizePronunciation(entry.pronunciation)
            guard Self.isKatakana(pron) else {
                summary.failed += 1   // E-PRON-WORD-REJECTED-001（非カタカナ）。
                continue
            }

            if let existingEntry = bySurface[key] {
                let same = Self.normalizePronunciation(existingEntry.word.pronunciation) == pron
                    && existingEntry.word.accentType == entry.accentType
                if same {
                    summary.skipped += 1
                    continue
                }
                // 読み or アクセントが違う → 更新（uuid は GET 由来）。
                do {
                    _ = try await http.put(
                        url: wordURL(uuid: existingEntry.uuid, entry: entry, pronunciation: pron),
                        body: nil, headers: [:])
                    summary.updated += 1
                } catch {
                    summary.failed += 1   // E-PRON-WORD-REJECTED-001（422 等。全捕捉・継続）。
                }
            } else {
                // 既存に無い → 追加。
                do {
                    _ = try await http.post(
                        url: wordURL(uuid: nil, entry: entry, pronunciation: pron),
                        body: nil, headers: [:])
                    summary.added += 1
                } catch {
                    summary.failed += 1
                }
            }
        }
        return summary
    }

    /// 追加（POST /user_dict_word）・更新（PUT /user_dict_word/{uuid}）の URL。
    /// VOICEVOX はクエリパラメータ方式（body=nil）。日本語値は URLQueryItem が URL エンコードする。
    private func wordURL(uuid: String?, entry: PronunciationEntry, pronunciation: String) -> URL {
        var items = [
            URLQueryItem(name: "surface", value: entry.surface),
            URLQueryItem(name: "pronunciation", value: pronunciation),
            URLQueryItem(name: "accent_type", value: String(entry.accentType)),   // サーバ必須。常に送る。
        ]
        if let wordType = entry.wordType {
            items.append(URLQueryItem(name: "word_type", value: wordType))
        }
        if let priority = entry.priority {
            items.append(URLQueryItem(name: "priority", value: String(priority)))
        }
        let path = uuid.map { "user_dict_word/\($0)" } ?? "user_dict_word"
        return makeURL(path, items)
    }

    private func makeURL(_ path: String, _ items: [URLQueryItem]) -> URL {
        var components = URLComponents(
            url: base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !items.isEmpty { components.queryItems = items }
        return components.url!
    }

    /// NFKC（互換正規化＝全角/半角の差を吸収）→ NFC（正準合成）。
    /// `precomposedStringWithCompatibilityMapping` 単体は半角濁点を「ト＋合成用濁点 U+3099」のまま残すため、
    /// 正準合成を重ねて「ド」(U+30C9) まで合成する。
    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.precomposedStringWithCanonicalMapping
    }

    /// 突合キー：正規化（全角/半角の差を吸収）。`Mr.Children` ↔ `Ｍｒ．Ｃｈｉｌｄｒｅｎ` を一致させる。
    static func matchKey(_ surface: String) -> String {
        normalize(surface)
    }

    /// 読みの正規化：半角カナ → 全角カナ（濁点も合成）。
    static func normalizePronunciation(_ pronunciation: String) -> String {
        normalize(pronunciation)
    }

    /// 全角カタカナ（＋長音「ー」・中黒「・」）のみか。VOICEVOX は非カタカナ読みを 422 で弾く。
    static func isKatakana(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            (0x30A1...0x30FA).contains(scalar.value)   // ァ..ヺ（カタカナ）
                || scalar.value == 0x30FB              // ・（中黒）
                || scalar.value == 0x30FC              // ー（長音）
        }
    }
}
