import Foundation
import AIRadioCore

/// AppleScript を実行する抽象（テストで fake 差し替え可能にする）。
public protocol AppleScriptRunner: Sendable {
    /// AppleScript ソースを実行し標準出力（trim 済み）を返す。
    func run(_ source: String) async throws -> String
}

/// `/usr/bin/osascript` 経由で AppleScript を実行する実装。
public struct OsascriptRunner: AppleScriptRunner {
    public init() {}

    /// 複数行スクリプトは行ごとに `-e` を分けて渡す（1 つの `-e` に改行を詰めると
    /// osascript が文の区切りを解釈できず構文エラーになるため）。
    static func arguments(for source: String) -> [String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return ["-e", source] }
        return lines.flatMap { ["-e", String($0)] }
    }

    public func run(_ source: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = Self.arguments(for: source)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw SpotifyError.apiFailed("osascript 起動失敗: \(error)")
        }

        // EOF まで読んでからプロセス終了を待つ（パイプバッファ詰まり回避）。
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let err = String(data: errData, encoding: .utf8) ?? ""
            throw SpotifyError.apiFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let out = String(data: outData, encoding: .utf8) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
