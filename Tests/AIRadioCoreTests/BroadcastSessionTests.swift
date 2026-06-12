import Foundation
import Testing
import AIRadioCore

private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [BroadcastSession.State] = []
    var states: [BroadcastSession.State] { lock.withLock { _states } }
    func append(_ state: BroadcastSession.State) { lock.withLock { _states.append(state) } }
}

/// state が idle になるまで待つ（最大 ~1 秒、テストの決定性確保用）。
private func waitForIdle(_ session: BroadcastSession) async {
    for _ in 0..<100 {
        if await session.state == .idle { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@Suite("BroadcastSession")
struct BroadcastSessionTests {
    @Test("開始 → 放送クロージャ完了で自動的に idle へ（通知は broadcasting → idle の順）")
    func startAndAutoFinish() async {
        let recorder = StateRecorder()
        let session = BroadcastSession(onStateChange: { recorder.append($0) })

        let started = await session.start { /* 即終了する放送 */ }
        #expect(started)
        await waitForIdle(session)

        #expect(await session.state == .idle)
        #expect(recorder.states == [.broadcasting, .idle])
    }

    @Test("多重開始は拒否される")
    func rejectsDoubleStart() async {
        let session = BroadcastSession()
        let first = await session.start {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let second = await session.start { }
        #expect(first)
        #expect(!second)
        await session.stopAndWait()
        #expect(await session.state == .idle)
    }

    @Test("stop はキャンセル要求: 放送がキャンセルに応答して終わり idle へ")
    func stopCancelsBroadcast() async {
        let session = BroadcastSession()
        await session.start {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        #expect(await session.state == .broadcasting)
        await session.stop()
        await waitForIdle(session)
        #expect(await session.state == .idle)
    }

    @Test("stopAndWait は放送タスクの完了（後始末）まで待つ")
    func stopAndWaitWaitsForCompletion() async {
        let cleanedUp = StateRecorder()
        let session = BroadcastSession()
        await session.start {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            // 後始末（実機では pause がここに相当）。
            await Task { cleanedUp.append(.idle) }.value
        }
        await session.stopAndWait()
        #expect(cleanedUp.states.count == 1)  // 後始末完了後に戻っている
        #expect(await session.state == .idle)
    }

    @Test("停止後に再度開始できる")
    func restartableAfterStop() async {
        let session = BroadcastSession()
        await session.start {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        await session.stopAndWait()
        let restarted = await session.start { }
        #expect(restarted)
        await waitForIdle(session)
    }
}
