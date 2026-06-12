import Foundation
import Testing
import AIRadioCore
import AIRadioTestSupport

// waitForTrackToFinish の終端検知（S10 fix + S12 stale 耐性強化）の専用テスト。
// PlaybackSimulator は SpotifyController と Clock を兼ね、sleep で仮想再生位置が進む。

private let song = "spotify:track:SONG"
private let opTheme = "spotify:track:OP-THEME"

@Suite("waitForTrackToFinish")
struct WaitForTrackToFinishTests {
    @Test("正常系: チャンク寝で終端 5 秒手前まで → ポーリングで実終端を検知して戻る")
    func waitsUntilNaturalEnd() async throws {
        let simulator = PlaybackSimulator(durations: [song: 355])
        try await simulator.play(uri: song)
        try await simulator.waitForTrackToFinish(of: song, clock: simulator)
        // 終端（355 秒）近くまで見届けている。まとめ寝は recheck（30 秒）以下のチャンクのみ。
        #expect(simulator.currentPositionSeconds >= 350)
        #expect(simulator.sleeps.allSatisfy { $0 <= 30 })
    }

    @Test("S12 回帰: 別問い合わせの曲長が前の曲（183 秒）でも、同一スナップショットの曲長で最後まで待つ")
    func staleLegacyDurationDoesNotCutTrackShort() async throws {
        // 実際に踏んだバグ: OP テーマ BGM（183 秒）→ 冒頭曲（355 秒）の切替直後、
        // currentTrackDurationSeconds()（別リクエスト）が前の曲の 183 を返すと、
        // 旧実装は 183 秒地点（曲の途中）で打ち切って pause していた。
        let simulator = PlaybackSimulator(
            durations: [song: 355],
            legacyDurationOverride: 183   // 別問い合わせは常に stale な前曲の曲長を返す
        )
        try await simulator.play(uri: song)
        try await simulator.waitForTrackToFinish(of: song, clock: simulator)
        #expect(simulator.currentPositionSeconds >= 350)   // 183 秒で切らない
    }

    @Test("切替直後の stale スナップショット（前曲・paused）はスキップして待ち続ける")
    func staleFirstSnapshotIsIgnored() async throws {
        // trackwatch 診断で実測した応答: play 直後の 1 回目は前の曲の paused が返る。
        let simulator = PlaybackSimulator(
            durations: [song: 200],
            staleSnapshots: [PlayerState(state: .paused, trackUri: opTheme, positionSeconds: 0)]
        )
        try await simulator.play(uri: song)
        try await simulator.waitForTrackToFinish(of: song, clock: simulator)
        #expect(simulator.currentPositionSeconds >= 195)
    }

    @Test("スナップショットに曲長を持たない実装（AppleScript 等）は別問い合わせに倒して待つ")
    func fallsBackToLegacyDurationWhenSnapshotLacksIt() async throws {
        let simulator = PlaybackSimulator(
            durations: [song: 200],
            snapshotIncludesDuration: false
        )
        try await simulator.play(uri: song)
        try await simulator.waitForTrackToFinish(of: song, clock: simulator)
        #expect(simulator.currentPositionSeconds >= 195)
    }

    @Test("チャンク読み直しで「停止」が見えても 1 拍おいて再確認する（stale の paused で早切りしない）")
    func rechecksTransientPauseBeforeGivingUp() async throws {
        // 途中のポーリングで一度だけ stale な paused を返し、再確認では再生中が返る controller。
        final class FlakySpotify: SpotifyController, @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            private var position = 0.0
            func play(uri: String) async throws {}
            func pause() async throws {}
            func setVolume(_ percent: Int) async throws {}
            func seek(toSeconds seconds: Int) async throws {}
            func playerState() async throws -> PlayerState {
                lock.withLock {
                    calls += 1
                    position += 30   // 呼び出しごとに約 1 チャンクぶん進んだ体
                    if calls == 2 {  // 最初のチャンク後の読み直しだけ stale な paused
                        return PlayerState(state: .paused, trackUri: song, positionSeconds: 0)
                    }
                    let pos = min(position, 100)
                    return PlayerState(
                        state: pos >= 100 ? .paused : .playing,
                        trackUri: song, positionSeconds: pos, durationSeconds: 100)
                }
            }
            func currentTrackDurationSeconds() async throws -> Double { 100 }
        }
        final class SleepRecorder: Clock, @unchecked Sendable {
            private let lock = NSLock()
            private var _sleeps: [Double] = []
            let now = Date(timeIntervalSince1970: 0)
            var sleeps: [Double] { lock.withLock { _sleeps } }
            func sleep(seconds: Double) async throws { lock.withLock { _sleeps.append(seconds) } }
        }
        let spotify = FlakySpotify()
        let clock = SleepRecorder()
        try await spotify.waitForTrackToFinish(of: song, clock: clock)
        // stale な paused（2 回目の応答）で即 return せず、その後も待ち続けている
        // （チャンク寝が複数回 = 30 秒級の sleep が 2 回以上）。
        #expect(clock.sleeps.filter { $0 > 1 }.count >= 2)
    }
}
