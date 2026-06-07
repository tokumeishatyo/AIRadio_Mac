import Foundation
@testable import AIRadioInfra

/// テスト用 HTTP fake。リクエストを記録し、URL に応じた応答を返す/投げる。
final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let method: String
        let body: Data?
        let headers: [String: String]
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    var requests: [Request] { lock.withLock { _requests } }

    private let responder: @Sendable (URL) throws -> Data

    init(responder: @escaping @Sendable (URL) throws -> Data) {
        self.responder = responder
    }

    func post(url: URL, body: Data?, headers: [String: String]) async throws -> Data {
        lock.withLock { _requests.append(.init(url: url, method: "POST", body: body, headers: headers)) }
        return try responder(url)
    }

    func get(url: URL, headers: [String: String]) async throws -> Data {
        lock.withLock { _requests.append(.init(url: url, method: "GET", body: nil, headers: headers)) }
        return try responder(url)
    }
}
