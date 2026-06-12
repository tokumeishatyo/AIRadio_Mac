import Foundation

/// 放送タスクのライフサイクル管理（メニューバー UI から開始 / 停止する単位）。
/// 放送全体を 1 つの `Task` で回し、停止は `Task.cancel()`（CLAUDE.md §3-1）。
public actor BroadcastSession {
    public enum State: String, Sendable, Equatable {
        case idle
        case broadcasting
    }

    public private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private let onStateChange: (@Sendable (State) -> Void)?

    public init(onStateChange: (@Sendable (State) -> Void)? = nil) {
        self.onStateChange = onStateChange
    }

    /// 放送を開始する。すでに放送中なら何もせず false（多重開始の拒否）。
    /// `broadcast` はキャンセルに応答し、正常・失敗いずれでも return すること
    /// （`BroadcastEngine.run` を包む前提。完了で自動的に `idle` へ戻る）。
    @discardableResult
    public func start(_ broadcast: @escaping @Sendable () async -> Void) -> Bool {
        guard state == .idle else { return false }
        transition(to: .broadcasting)
        task = Task {
            // actor 内で生成した Task は actor 分離を継承する（finish は直接呼べる）。
            await broadcast()
            self.finish()
        }
        return true
    }

    /// 停止（キャンセル要求のみ。静寂化は放送側の後始末が担う）。
    public func stop() {
        task?.cancel()
    }

    /// 停止し、放送タスクの完了（pause 後始末まで）を待つ。終了処理用。
    public func stopAndWait() async {
        task?.cancel()
        await task?.value
    }

    private func finish() {
        task = nil
        transition(to: .idle)
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange?(newState)
    }
}
