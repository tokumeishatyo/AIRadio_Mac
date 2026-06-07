import Foundation
import Network
import AIRadioCore

/// OAuth リダイレクト用のローカル HTTP サーバ。`127.0.0.1:<port>/callback?code=...` を 1 回受領し、
/// 認可コードを返す。Network framework の `NWListener` を使う。
final class LoopbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var listener: NWListener?

    /// 指定ポートで待受し、最初のコールバックから `code` を取り出して返す。
    func waitForCode(port: UInt16) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection, continuation: continuation)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state {
                        self?.finish(continuation, with: .failure(error))
                    }
                }
                listener.start(queue: .global())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func handle(_ connection: NWConnection, continuation: CheckedContinuation<String, Error>) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let request = String(data: data, encoding: .utf8) {
                let code = Self.queryItem("code", in: request)
                let errorParam = Self.queryItem("error", in: request)
                let html = "<html><head><meta charset=\"utf-8\"></head><body>認証が完了しました。このウィンドウを閉じてください。</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if let code {
                    self.finish(continuation, with: .success(code))
                } else {
                    self.finish(continuation, with: .failure(SpotifyError.authFailed(errorParam ?? "認可コードを取得できませんでした")))
                }
            } else if let error {
                self.finish(continuation, with: .failure(error))
            }
        }
    }

    private func finish(_ continuation: CheckedContinuation<String, Error>, with result: Result<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        listener?.cancel()
        continuation.resume(with: result)
    }

    /// HTTP リクエスト文字列の 1 行目（`GET /callback?code=... HTTP/1.1`）からクエリ値を取り出す。
    static func queryItem(_ name: String, in request: String) -> String? {
        let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first ?? Substring(request)
        let tokens = firstLine.split(separator: " ")
        guard tokens.count >= 2 else { return nil }
        let pathAndQuery = String(tokens[1])
        guard let query = pathAndQuery.split(separator: "?").dropFirst().first else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name {
                return String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return nil
    }
}
