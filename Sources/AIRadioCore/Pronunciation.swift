import Foundation

/// 読み辞書のエントリ（仕様 s19a）。VOICEVOX ユーザー辞書へ同期する 1 語。
/// `surface`（表記）が入力テキストに現れたら、指定の `pronunciation`（読み）・`accentType` で発音させる。
public struct PronunciationEntry: Sendable, Equatable {
    /// 表記（例: "栄光の架橋" / "Mr.Children"）。
    public let surface: String
    /// 読み（全角カタカナ。ひらがな・半角カナは VOICEVOX が弾く。同期側で正規化・検証する）。
    public let pronunciation: String
    /// アクセント型（音が下がるモーラ位置。0 = 平板。VOICEVOX では必須なので未指定でも 0 を送る）。
    public let accentType: Int
    /// 品詞種別（任意。PROPER_NOUN / COMMON_NOUN / VERB / ADJECTIVE / SUFFIX）。
    public let wordType: String?
    /// 優先度（任意。0–10。未指定時のサーバ既定は 5）。
    public let priority: Int?

    public init(
        surface: String,
        pronunciation: String,
        accentType: Int = 0,
        wordType: String? = nil,
        priority: Int? = nil
    ) {
        self.surface = surface
        self.pronunciation = pronunciation
        self.accentType = accentType
        self.wordType = wordType
        self.priority = priority
    }
}
