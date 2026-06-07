import Foundation
@testable import AIRadioInfra

/// テスト用 AppleScript fake。実行されたスクリプトを記録し、応答を返す。
/// 固定出力（`init(output:)`）か、スクリプト内容に応じた応答（`init(responder:)`）を選べる。
final class FakeAppleScriptRunner: AppleScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _scripts: [String] = []
    var scripts: [String] { lock.withLock { _scripts } }

    private let responder: @Sendable (String) -> String

    init(responder: @escaping @Sendable (String) -> String = { _ in "" }) {
        self.responder = responder
    }

    init(output: String) {
        self.responder = { _ in output }
    }

    func run(_ source: String) async throws -> String {
        lock.withLock { _scripts.append(source) }
        return responder(source)
    }
}
