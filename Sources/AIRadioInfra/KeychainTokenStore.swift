import Foundation
import Security

/// 文字列トークンの保管抽象（テストで fake 差し替え可能にする）。
public protocol TokenStore: Sendable {
    func save(_ value: String)
    func load() -> String?
    func delete()
}

/// macOS Keychain に refresh トークンを保管する `TokenStore` 実装。
public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let account: String

    public init(service: String = "AIRadio.Spotify", account: String = "refresh_token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ value: String) {
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    public func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
