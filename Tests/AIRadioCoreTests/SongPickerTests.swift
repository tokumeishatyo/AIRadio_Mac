import Foundation
import Testing
import AIRadioCore
import AIRadioTestSupport

private func request() -> SongRequest {
    SongRequest(
        context: "ラジオコーナー「フリートーク」（テーマ: 最近気になっていること）の締めにかける曲",
        promptHint: "落ち着いた曲",
        fallbackTrackUri: "spotify:track:FALLBACK"
    )
}

/// 検索が常に失敗する TrackSearcher。
private struct ThrowingSearcher: TrackSearcher {
    func search(query: String, limit: Int) async throws -> [TrackInfo] {
        throw SpotifyError.searchFailed("down")
    }
    func isPlayable(_ uri: String) async throws -> Bool { false }
}

@Suite("SongPicker: 候補パース")
struct SongPickerParseTests {
    @Test("「曲名 - アーティスト」形式の行を抽出し、番号・箇条書き・形式外を整理する")
    func parsesCandidates() {
        let raw = """
        以下が候補です。
        1. 夜に駆ける - YOASOBI
        - Lemon - 米津玄師
        * 2) マリーゴールド - あいみょん
        ただの文章の行
        Pretender - Official髭男dism
        """
        let candidates = SongPicker.parseCandidates(raw)
        #expect(candidates.count == 4)
        #expect(candidates[0] == ("夜に駆ける", "YOASOBI"))
        #expect(candidates[1] == ("Lemon", "米津玄師"))
        #expect(candidates[2] == ("マリーゴールド", "あいみょん"))
        #expect(candidates[3] == ("Pretender", "Official髭男dism"))
    }

    @Test("ハイフンを含む曲名は最初の「 - 」で分割する")
    func splitsAtFirstSeparator() {
        let candidates = SongPicker.parseCandidates("バイバイ - サヨナラ - テスター")
        #expect(candidates.count == 1)
        #expect(candidates[0] == ("バイバイ", "サヨナラ - テスター"))
    }
}

@Suite("SongPicker: プレフライト")
struct SongPickerPickTests {
    @Test("最初に再生可能な候補で確定し、検索クエリは曲名+アーティスト")
    func picksFirstPlayable() async throws {
        let llm = ScriptedLLM(responses: ["夜に駆ける - YOASOBI"])
        let searcher = FakeTrackSearcher(results: [
            TrackInfo(uri: "spotify:track:NG", title: "夜に駆ける", artist: "誰か", isPlayable: false),
            TrackInfo(uri: "spotify:track:OK", title: "夜に駆ける", artist: "YOASOBI", isPlayable: true),
        ])
        let picker = SongPicker(llm: llm, searcher: searcher)
        let track = try await picker.pick(request())
        #expect(track.uri == "spotify:track:OK")
        #expect(searcher.queries == ["夜に駆ける YOASOBI"])
    }

    @Test("再生可能な候補がなければフォールバック曲（曲名不明）")
    func fallsBackWhenNothingPlayable() async throws {
        let llm = ScriptedLLM(responses: ["夜に駆ける - YOASOBI\nLemon - 米津玄師"])
        let searcher = FakeTrackSearcher(results: [])
        let picker = SongPicker(llm: llm, searcher: searcher)
        let track = try await picker.pick(request())
        #expect(track.uri == "spotify:track:FALLBACK")
        #expect(track.title.isEmpty)
        #expect(track.artist.isEmpty)
    }

    @Test("検索の失敗は握り潰してフォールバックに倒す")
    func toleratesSearchFailure() async throws {
        let llm = ScriptedLLM(responses: ["夜に駆ける - YOASOBI"])
        let picker = SongPicker(llm: llm, searcher: ThrowingSearcher())
        let track = try await picker.pick(request())
        #expect(track.uri == "spotify:track:FALLBACK")
    }

    @Test("LLM の失敗は伝播する")
    func propagatesLlmFailure() async {
        let picker = SongPicker(llm: ScriptedLLM(responses: []), searcher: FakeTrackSearcher())
        await #expect(throws: LLMError.self) {
            _ = try await picker.pick(request())
        }
    }

    @Test("選曲プロンプトにテーマとヒントが入る")
    func promptContainsThemeAndHint() {
        let request = SongPicker.makeRequest(request())
        #expect(request.prompt.contains("最近気になっていること"))
        #expect(request.prompt.contains("落ち着いた曲"))
        #expect(request.prompt.contains("曲名 - アーティスト名"))
    }
}
