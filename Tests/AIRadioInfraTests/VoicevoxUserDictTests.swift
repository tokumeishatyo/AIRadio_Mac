import Testing
import Foundation
import AIRadioCore
@testable import AIRadioInfra

struct VoicevoxUserDictTests {
    private let endpoint = "http://127.0.0.1:50021/"

    /// GET /user_dict と書き込み（POST/PUT）を URL の末尾要素で振り分ける fake。
    private func fake(getJSON: String, write: @escaping @Sendable (URL) throws -> Data) -> FakeHTTPClient {
        FakeHTTPClient { url in
            url.lastPathComponent == "user_dict" ? Data(getJSON.utf8) : try write(url)
        }
    }

    /// VOICEVOX が ASCII（空白以外）を全角化して保存する挙動を再現（実機 v0.25.2 で確認した癖）。
    private func toFullWidth(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0x21...0x7E).contains(scalar.value)
                ? Unicode.Scalar(scalar.value + 0xFEE0)! : scalar
        }))
    }

    private func queryValue(_ request: FakeHTTPClient.Request, _ name: String) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    private var writes: (FakeHTTPClient) -> [FakeHTTPClient.Request] {
        { $0.requests.filter { $0.method == "POST" || $0.method == "PUT" } }
    }

    @Test("空辞書 → 全エントリを POST（追加）。クエリに surface/pronunciation/accent_type（既定0）が載る")
    func emptyDictAddsAll() async {
        let fake = fake(getJSON: "{}") { _ in Data("\"uuid\"".utf8) }
        let dict = VoicevoxUserDict(endpoint: endpoint, http: fake)
        let summary = await dict.sync(entries: [
            PronunciationEntry(surface: "栄光の架橋", pronunciation: "エイコウノカケハシ"),
            PronunciationEntry(surface: "Mr.Children", pronunciation: "ミスターチルドレン"),
        ])
        #expect(summary == { var s = PronunciationSyncSummary(); s.added = 2; return s }())
        let posts = fake.requests.filter { $0.method == "POST" }
        #expect(posts.count == 2)
        #expect(posts.allSatisfy { $0.url.lastPathComponent == "user_dict_word" })
        #expect(queryValue(posts[0], "surface") == "栄光の架橋")
        #expect(queryValue(posts[0], "pronunciation") == "エイコウノカケハシ")
        #expect(queryValue(posts[0], "accent_type") == "0")   // 未指定でも 0 を送る
        #expect(posts[0].body == nil)
    }

    @Test("冪等の核: GET が全角 surface・同一読みを返せば、config の半角 surface は skip（POST/PUT なし）")
    func normalizedSurfaceMatchSkips() async {
        let getSurface = toFullWidth("Mr.Children")   // VOICEVOX 保存形（全角）
        let json = "{\"u1\":{\"surface\":\"\(getSurface)\",\"pronunciation\":\"ミスターチルドレン\",\"accent_type\":0}}"
        let fake = fake(getJSON: json) { _ in Data("\"uuid\"".utf8) }
        let dict = VoicevoxUserDict(endpoint: endpoint, http: fake)
        let summary = await dict.sync(entries: [
            PronunciationEntry(surface: "Mr.Children", pronunciation: "ミスターチルドレン"),
        ])
        #expect(summary.skipped == 1)
        #expect(summary.added == 0 && summary.updated == 0)
        #expect(writes(fake).isEmpty)
    }

    @Test("読みが違えば PUT で更新（uuid は GET 由来）。priority 差では更新しない")
    func differentPronunciationUpdates() async {
        let json = "{\"u9\":{\"surface\":\"栄光の架橋\",\"pronunciation\":\"エイコウ\",\"accent_type\":0}}"
        let fake = fake(getJSON: json) { _ in Data("".utf8) }
        let dict = VoicevoxUserDict(endpoint: endpoint, http: fake)
        let summary = await dict.sync(entries: [
            PronunciationEntry(surface: "栄光の架橋", pronunciation: "エイコウノカケハシ", priority: 9),
        ])
        #expect(summary.updated == 1)
        let puts = fake.requests.filter { $0.method == "PUT" }
        #expect(puts.count == 1)
        #expect(puts[0].url.lastPathComponent == "u9")   // GET 由来の uuid をパスに使う
        #expect(queryValue(puts[0], "pronunciation") == "エイコウノカケハシ")
    }

    @Test("読みもアクセントも同一なら何もしない（priority/word_type は比較対象外）")
    func identicalIsSkipped() async {
        let json = "{\"u1\":{\"surface\":\"栄光の架橋\",\"pronunciation\":\"エイコウノカケハシ\",\"accent_type\":0}}"
        let fake = fake(getJSON: json) { _ in Data("".utf8) }
        let dict = VoicevoxUserDict(endpoint: endpoint, http: fake)
        let summary = await dict.sync(entries: [
            PronunciationEntry(surface: "栄光の架橋", pronunciation: "エイコウノカケハシ", priority: 7),
        ])
        #expect(summary.skipped == 1)
        #expect(writes(fake).isEmpty)
    }

    @Test("半角カナ読みは NFKC で全角化して送る")
    func halfWidthKatakanaNormalizedOnSend() async {
        let fake = fake(getJSON: "{}") { _ in Data("\"uuid\"".utf8) }
        let dict = VoicevoxUserDict(endpoint: endpoint, http: fake)
        let summary = await dict.sync(entries: [
            PronunciationEntry(surface: "Mr.Children", pronunciation: "ﾐｽﾀｰﾁﾙﾄﾞﾚﾝ"),
        ])
        #expect(summary.added == 1)
        let posts = fake.requests.filter { $0.method == "POST" }
        #expect(queryValue(posts[0], "pronunciation") == "ミスターチルドレン")
    }

    @Test("非カタカナ読み（ひらがな）は送らず failed")
    func nonKatakanaRejected() async {
        let fake = fake(getJSON: "{}") { _ in Data("\"uuid\"".utf8) }
        let dict = VoicevoxUserDict(endpoint: endpoint, http: fake)
        let summary = await dict.sync(entries: [
            PronunciationEntry(surface: "栄光の架橋", pronunciation: "えいこうのかけはし"),
        ])
        #expect(summary.failed == 1)
        #expect(summary.added == 0)
        #expect(writes(fake).isEmpty)
    }

    @Test("word_type / priority は指定時のみクエリに載る")
    func optionalParamsOnlyWhenPresent() async {
        let fake = fake(getJSON: "{}") { _ in Data("\"uuid\"".utf8) }
        let dict = VoicevoxUserDict(endpoint: endpoint, http: fake)
        _ = await dict.sync(entries: [
            PronunciationEntry(surface: "あ", pronunciation: "ア", wordType: "PROPER_NOUN", priority: 8),
            PronunciationEntry(surface: "い", pronunciation: "イ"),
        ])
        let posts = fake.requests.filter { $0.method == "POST" }
        #expect(queryValue(posts[0], "word_type") == "PROPER_NOUN")
        #expect(queryValue(posts[0], "priority") == "8")
        #expect(queryValue(posts[1], "word_type") == nil)
        #expect(queryValue(posts[1], "priority") == nil)
    }

    @Test("GET が URLError → unreachable・書き込みなし・throw しない")
    func getUrlErrorMarksUnreachable() async {
        let fake = FakeHTTPClient { url in
            if url.lastPathComponent == "user_dict" { throw URLError(.cannotConnectToHost) }
            return Data("\"uuid\"".utf8)
        }
        let dict = VoicevoxUserDict(endpoint: endpoint, http: fake)
        let summary = await dict.sync(entries: [
            PronunciationEntry(surface: "栄光の架橋", pronunciation: "エイコウノカケハシ"),
        ])
        #expect(summary.unreachable)
        #expect(writes(fake).isEmpty)
    }

    @Test("GET が非2xx（HTTPClientError.status）→ unreachable")
    func getStatusErrorMarksUnreachable() async {
        let fake = FakeHTTPClient { url in
            if url.lastPathComponent == "user_dict" { throw HTTPClientError.status(500) }
            return Data("\"uuid\"".utf8)
        }
        let dict = VoicevoxUserDict(endpoint: endpoint, http: fake)
        let summary = await dict.sync(entries: [
            PronunciationEntry(surface: "栄光の架橋", pronunciation: "エイコウノカケハシ"),
        ])
        #expect(summary.unreachable)
    }

    @Test("個別 POST が 422 → そのエントリだけ failed・他は継続・throw しない")
    func perEntryFailureContinues() async {
        let fake = FakeHTTPClient { url in
            if url.lastPathComponent == "user_dict" { return Data("{}".utf8) }
            throw HTTPClientError.status(422)
        }
        let dict = VoicevoxUserDict(endpoint: endpoint, http: fake)
        let summary = await dict.sync(entries: [
            PronunciationEntry(surface: "栄光の架橋", pronunciation: "エイコウノカケハシ"),
            PronunciationEntry(surface: "Mr.Children", pronunciation: "ミスターチルドレン"),
        ])
        #expect(summary.failed == 2)
        #expect(summary.added == 0)
    }

    @Test("停止（Task キャンセル）後は POST/PUT を出さない")
    func cancelledSkipsWrites() async {
        let fake = fake(getJSON: "{}") { _ in Data("\"uuid\"".utf8) }
        let dict = VoicevoxUserDict(endpoint: endpoint, http: fake)
        let entries = [PronunciationEntry(surface: "栄光の架橋", pronunciation: "エイコウノカケハシ")]
        let task = Task { await dict.sync(entries: entries) }
        task.cancel()
        _ = await task.value
        #expect(writes(fake).isEmpty)
    }

    @Test("エントリが空なら GET すらしない")
    func emptyEntriesDoesNothing() async {
        let fake = fake(getJSON: "{}") { _ in Data("\"uuid\"".utf8) }
        let dict = VoicevoxUserDict(endpoint: endpoint, http: fake)
        let summary = await dict.sync(entries: [])
        #expect(summary == PronunciationSyncSummary())
        #expect(fake.requests.isEmpty)
    }

    @Test("正規化・カタカナ判定のユニット")
    func normalizationHelpers() {
        #expect(VoicevoxUserDict.matchKey(toFullWidth("Mr.Children")) == "Mr.Children")
        #expect(VoicevoxUserDict.normalizePronunciation("ﾐｽﾀｰ") == "ミスター")
        #expect(VoicevoxUserDict.isKatakana("ミスターチルドレン"))
        #expect(VoicevoxUserDict.isKatakana("エイコウ・ノ") )   // 中黒・長音は許容
        #expect(!VoicevoxUserDict.isKatakana("みすたー"))        // ひらがな
        #expect(!VoicevoxUserDict.isKatakana("Mr"))             // 英字
        #expect(!VoicevoxUserDict.isKatakana(""))
    }
}
