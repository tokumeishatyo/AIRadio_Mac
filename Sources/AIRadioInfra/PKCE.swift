import Foundation
import CryptoKit

/// OAuth PKCE（Proof Key for Code Exchange）のユーティリティ。
public enum PKCE {
    /// code_verifier を生成する（43〜128 文字の base64url 文字列）。
    public static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    /// code_challenge = base64url(SHA256(code_verifier))。
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64url(Data(digest))
    }

    /// base64url エンコード（パディング・記号を URL 安全に）。
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
