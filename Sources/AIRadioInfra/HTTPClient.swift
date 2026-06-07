import Foundation

/// HTTP 通信の抽象（VOICEVOX / Spotify / News / 天気 が共通利用）。
public protocol HTTPClient: Sendable {
    func get(url: URL, headers: [String: String]) async throws -> Data
    func post(url: URL, body: Data?, headers: [String: String]) async throws -> Data
    func put(url: URL, body: Data?, headers: [String: String]) async throws -> Data
}

/// HTTP のステータス異常。
public enum HTTPClientError: Error, Equatable {
    case status(Int)
}

/// URLSession ベースの `HTTPClient` 実装。
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(url: URL, headers: [String: String]) async throws -> Data {
        try await send(url: url, method: "GET", body: nil, headers: headers)
    }

    public func post(url: URL, body: Data?, headers: [String: String]) async throws -> Data {
        try await send(url: url, method: "POST", body: body, headers: headers)
    }

    public func put(url: URL, body: Data?, headers: [String: String]) async throws -> Data {
        try await send(url: url, method: "PUT", body: body, headers: headers)
    }

    private func send(url: URL, method: String, body: Data?, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPClientError.status(http.statusCode)
        }
        return data
    }
}
