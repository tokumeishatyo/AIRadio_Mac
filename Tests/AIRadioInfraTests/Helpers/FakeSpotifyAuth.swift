import Foundation
@testable import AIRadioInfra

/// テスト用トークンプロバイダ（固定アクセストークンを返す）。
struct FakeTokenProvider: SpotifyTokenProvider {
    let token: String
    init(token: String = "TOK") { self.token = token }
    func validAccessToken() async throws -> String { token }
}

/// テスト用のインメモリ TokenStore。
final class FakeTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(initial: String? = nil) { value = initial }
    func save(_ value: String) { lock.withLock { self.value = value } }
    func load() -> String? { lock.withLock { value } }
    func delete() { lock.withLock { value = nil } }
}
