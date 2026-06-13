import Foundation
import Testing
import AIRadioCore

private let blueprint = ProgramBlueprint(
    title: "テスト番組",
    anchorDjId: "zundamon",
    song: SongSegmentSpec(fallbackTrackUri: "spotify:track:F"),
    talkCornerId: "free_talk",
    letterCornerId: "letter",
    newsDjId: "ryusei"
)

/// プランの先頭から並びを列挙する（nil = 番組終了）。talk は corner_id で letter / guest を区別。
private func layout(_ plan: ProgramPlan, upTo limit: Int = 40) -> [String] {
    var result: [String] = []
    for index in 0..<limit {
        guard let segment = plan.segment(at: index) else { break }
        switch segment.kind {
        case .talk:
            switch segment.cornerId {
            case "letter": result.append("letter")
            case "guest": result.append("guest")
            default: result.append("talk")
            }
        default:
            result.append(segment.kind.rawValue)
        }
    }
    return result
}

/// ゲストコーナー有効版の blueprint（guestCornerId = "guest"）。
private let guestBlueprint = ProgramBlueprint(
    title: "テスト番組",
    anchorDjId: "zundamon",
    song: SongSegmentSpec(fallbackTrackUri: "spotify:track:F"),
    talkCornerId: "free_talk",
    letterCornerId: "letter",
    newsDjId: "ryusei",
    guestCornerId: "guest"
)

@Suite("ProgramPlan（番組生成規則、s13 §2）")
struct ProgramPlanTests {
    @Test("N=4（偶数）: トーク 2 本ごとにお便り → ニュース、最後に ED")
    func evenCount() {
        let plan = ProgramPlan(blueprint: blueprint, length: .corners(4))
        #expect(layout(plan) == [
            "opening", "song",
            "talk", "talk", "letter", "news",
            "talk", "talk", "letter", "news",
            "ending",
        ])
        #expect(plan.totalSegmentCount == 11)
        #expect(plan.segment(at: 11) == nil)
    }

    @Test("N=3（奇数）: 端数のトークの後はお便りを挟まず ED へ")
    func oddCountSkipsLetterBeforeEnding() {
        let plan = ProgramPlan(blueprint: blueprint, length: .corners(3))
        #expect(layout(plan) == [
            "opening", "song",
            "talk", "talk", "letter", "news",
            "talk",
            "ending",
        ])
        #expect(plan.totalSegmentCount == 8)
    }

    @Test("N=1: OP → 冒頭曲 → トーク → ED の最小構成")
    func singleCorner() {
        let plan = ProgramPlan(blueprint: blueprint, length: .corners(1))
        #expect(layout(plan) == ["opening", "song", "talk", "ending"])
        #expect(plan.totalSegmentCount == 4)
    }

    @Test("N=10: トーク 10 本 + お便り/ニュース 5 組 + OP/冒頭曲/ED = 23 セグメント")
    func tenCorners() {
        let plan = ProgramPlan(blueprint: blueprint, length: .corners(10))
        let segments = layout(plan)
        #expect(plan.totalSegmentCount == 23)
        #expect(segments.count == 23)
        #expect(segments.filter { $0 == "talk" }.count == 10)
        #expect(segments.filter { $0 == "letter" }.count == 5)
        #expect(segments.filter { $0 == "news" }.count == 5)
        #expect(segments.last == "ending")
    }

    @Test("エンドレス: パターンを無限に繰り返し、ED は出ない")
    func endlessRepeatsWithoutEnding() {
        let plan = ProgramPlan(blueprint: blueprint, length: .endless)
        #expect(plan.totalSegmentCount == nil)
        let prefix = layout(plan, upTo: 14)
        #expect(prefix == [
            "opening", "song",
            "talk", "talk", "letter", "news",
            "talk", "talk", "letter", "news",
            "talk", "talk", "letter", "news",
        ])
        #expect(plan.segment(at: 1000) != nil)
        #expect(!prefix.contains("ending"))
    }

    @Test("セグメントの中身: OP は critical、song は blueprint の設定、news は dj_id を引き継ぐ")
    func segmentDetails() {
        let plan = ProgramPlan(blueprint: blueprint, length: .corners(2))
        #expect(plan.segment(at: 0)?.critical == true)
        #expect(plan.segment(at: 1)?.song == blueprint.song)
        #expect(plan.segment(at: 2)?.cornerId == "free_talk")
        #expect(plan.segment(at: 4)?.cornerId == "letter")
        #expect(plan.segment(at: 5)?.djId == "ryusei")
    }
}

@Suite("ProgramPlan: ゲストコーナー挿入（s14 §3）")
struct ProgramPlanGuestTests {
    @Test("N=2: 最初のニュースの直後にゲストが 1 つ入り、total +1")
    func guestAfterFirstNewsN2() {
        let plan = ProgramPlan(blueprint: guestBlueprint, length: .corners(2))
        #expect(layout(plan) == [
            "opening", "song",
            "talk", "talk", "letter", "news", "guest",
            "ending",
        ])
        #expect(plan.totalSegmentCount == 8)  // ゲストなしは 7 → +1
        #expect(plan.segment(at: 6)?.cornerId == "guest")
    }

    @Test("N=4: ゲストは最初のニュース直後だけ（2 回目のニュース後には入らない）")
    func guestOnlyAfterFirstNews() {
        let plan = ProgramPlan(blueprint: guestBlueprint, length: .corners(4))
        #expect(layout(plan) == [
            "opening", "song",
            "talk", "talk", "letter", "news", "guest",
            "talk", "talk", "letter", "news",
            "ending",
        ])
        #expect(layout(plan).filter { $0 == "guest" }.count == 1)
        #expect(plan.totalSegmentCount == 12)  // ゲストなし 11 → +1
    }

    @Test("エンドレス: ゲストは最初のニュース直後に 1 回だけ（以降は出ない）")
    func guestOnceInEndless() {
        let plan = ProgramPlan(blueprint: guestBlueprint, length: .endless)
        let prefix = layout(plan, upTo: 20)
        #expect(prefix == [
            "opening", "song",
            "talk", "talk", "letter", "news", "guest",
            "talk", "talk", "letter", "news",
            "talk", "talk", "letter", "news",
            "talk", "talk", "letter", "news",
            "talk",
        ])
        #expect(prefix.filter { $0 == "guest" }.count == 1)
        #expect(plan.totalSegmentCount == nil)
    }

    @Test("N=1: ニュースが無いのでゲストも無し")
    func noGuestWithoutNews() {
        let plan = ProgramPlan(blueprint: guestBlueprint, length: .corners(1))
        #expect(layout(plan) == ["opening", "song", "talk", "ending"])
        #expect(!layout(plan).contains("guest"))
        #expect(plan.totalSegmentCount == 4)  // +1 されない
    }

    @Test("guestCornerId 未設定ならゲストは入らない（従来どおり）")
    func noGuestWhenDisabled() {
        let plan = ProgramPlan(blueprint: blueprint, length: .corners(2))  // guestCornerId nil
        #expect(!layout(plan).contains("guest"))
        #expect(plan.totalSegmentCount == 7)
    }
}

@Suite("ProgramLength")
struct ProgramLengthTests {
    @Test("rawValue 往復（\"10\" / \"endless\"）と不正値")
    func rawValueRoundTrip() {
        #expect(ProgramLength(rawValue: "10") == .corners(10))
        #expect(ProgramLength(rawValue: "endless") == .endless)
        #expect(ProgramLength.corners(20).rawValue == "20")
        #expect(ProgramLength.endless.rawValue == "endless")
        #expect(ProgramLength(rawValue: "abc") == nil)
        #expect(ProgramLength(rawValue: "-1") == nil)
    }
}
