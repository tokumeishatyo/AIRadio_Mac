import Foundation
@testable import AIRadioInfra

/// テスト用 AppleScript fake。実行されたスクリプトを記録し、固定出力を返す。
final class FakeAppleScriptRunner: AppleScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _scripts: [String] = []
    var scripts: [String] { lock.withLock { _scripts } }

    private let output: String

    init(output: String = "") {
        self.output = output
    }

    func run(_ source: String) async throws -> String {
        lock.withLock { _scripts.append(source) }
        return output
    }
}
