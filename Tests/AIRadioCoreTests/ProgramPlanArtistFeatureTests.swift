import Foundation
import Testing
import AIRadioCore

private let featureBlueprint = ProgramBlueprint(
    title: "テスト番組",
    anchorDjId: "zundamon",
    song: SongSegmentSpec(fallbackTrackUri: "spotify:track:F"),
    talkCornerId: "free_talk",
    letterCornerId: "letter",
    newsDjId: "ryusei",
    guestCornerId: "guest",
    artistFeatureCornerId: "artist_feature"
)

/// guest 無効・artist_feature だけ設定（従属確認用）。
private let featureOnlyBlueprint = ProgramBlueprint(
    title: "テスト番組",
    anchorDjId: "zundamon",
    song: SongSegmentSpec(fallbackTrackUri: "spotify:track:F"),
    talkCornerId: "free_talk",
    letterCornerId: "letter",
    newsDjId: "ryusei",
    artistFeatureCornerId: "artist_feature"
)

private func layout(_ plan: ProgramPlan, upTo limit: Int = 40) -> [String] {
    var result: [String] = []
    for index in 0..<limit {
        guard let segment = plan.segment(at: index) else { break }
        switch segment.kind {
        case .artistFeature:
            result.append("feature")
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

@Suite("ProgramPlan: アーティスト特集挿入（s15 §3）")
struct ProgramPlanArtistFeatureTests {
    @Test("N=2: ニュース → ゲスト → 特集 → ED、total は +2")
    func featureAfterGuestN2() {
        let plan = ProgramPlan(blueprint: featureBlueprint, length: .corners(2))
        #expect(layout(plan) == [
            "opening", "song",
            "talk", "talk", "letter", "news", "guest", "feature",
            "ending",
        ])
        #expect(plan.totalSegmentCount == 9)   // ゲスト/特集なし 7 → +2
        #expect(plan.segment(at: 7)?.kind == .artistFeature)
        #expect(plan.segment(at: 7)?.cornerId == "artist_feature")
        #expect(plan.segment(at: 7)?.critical == false)
    }

    @Test("N=3（奇数）: 端数トークの位置と ED が割り込み 2 つぶん後ろにずれる")
    func featureOddN3() {
        let plan = ProgramPlan(blueprint: featureBlueprint, length: .corners(3))
        #expect(layout(plan) == [
            "opening", "song",
            "talk", "talk", "letter", "news", "guest", "feature",
            "talk",
            "ending",
        ])
        #expect(plan.totalSegmentCount == 10)   // 8 → +2
    }

    @Test("N=4: 特集は最初のニュース直後だけ（2 回目のニュース後には入らない）")
    func featureOnlyOnceN4() {
        let plan = ProgramPlan(blueprint: featureBlueprint, length: .corners(4))
        #expect(layout(plan) == [
            "opening", "song",
            "talk", "talk", "letter", "news", "guest", "feature",
            "talk", "talk", "letter", "news",
            "ending",
        ])
        #expect(layout(plan).filter { $0 == "feature" }.count == 1)
        #expect(plan.totalSegmentCount == 13)   // 11 → +2
    }

    @Test("N=5: 端数トークの位置も割り込みぶん後ろにずれる")
    func featureN5() {
        let plan = ProgramPlan(blueprint: featureBlueprint, length: .corners(5))
        #expect(layout(plan) == [
            "opening", "song",
            "talk", "talk", "letter", "news", "guest", "feature",
            "talk", "talk", "letter", "news",
            "talk",
            "ending",
        ])
    }

    @Test("エンドレス: 特集は最初のニュース直後に 1 回だけ")
    func featureOnceEndless() {
        let plan = ProgramPlan(blueprint: featureBlueprint, length: .endless)
        let prefix = layout(plan, upTo: 22)
        #expect(prefix.filter { $0 == "feature" }.count == 1)
        #expect(Array(prefix.prefix(8)) == [
            "opening", "song", "talk", "talk", "letter", "news", "guest", "feature",
        ])
        #expect(plan.totalSegmentCount == nil)
    }

    @Test("特集はゲストに従属: guest 無効なら特集も入らない")
    func featureRequiresGuest() {
        let plan = ProgramPlan(blueprint: featureOnlyBlueprint, length: .corners(4))
        #expect(!layout(plan).contains("feature"))
        #expect(plan.includesArtistFeature == false)
    }

    @Test("N=1: ニュースが無いのでゲストも特集も無し")
    func noFeatureWithoutNews() {
        let plan = ProgramPlan(blueprint: featureBlueprint, length: .corners(1))
        #expect(layout(plan) == ["opening", "song", "talk", "ending"])
        #expect(plan.totalSegmentCount == 4)
    }
}
