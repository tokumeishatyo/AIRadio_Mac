import Foundation
import AppKit
import AIRadioCore

/// Spotify アクセストークンの供給抽象（検索・再生が利用）。
public protocol SpotifyTokenProvider: Sendable {
    func validAccessToken() async throws -> String
}

/// Authorization Code + PKCE による Spotify 認証。アクセストークンを期限付きでキャッシュし、
/// refresh トークンで無音更新する。初回は `authorize()` でブラウザログイン。
public actor SpotifyAuth: SpotifyTokenProvider {
    private let clientId: String
    private let redirectUri: String
    private let loopbackPort: UInt16
    private let scopes: [String]
    private let store: any TokenStore
    private let http: any HTTPClient
    private let clock: any Clock

    private var accessToken: String?
    private var expiry: Date = .distantPast

    public init(
        clientId: String,
        redirectUri: String,
        loopbackPort: UInt16,
        scopes: [String],
        store: any TokenStore,
        http: any HTTPClient,
        clock: any Clock
    ) {
        self.clientId = clientId
        self.redirectUri = redirectUri
        self.loopbackPort = loopbackPort
        self.scopes = scopes
        self.store = store
        self.http = http
        self.clock = clock
    }

    public func validAccessToken() async throws -> String {
        if let token = accessToken, clock.now < expiry {
            return token
        }
        guard let refreshToken = store.load() else {
            throw SpotifyError.authRequired
        }
        return try await refreshAccessToken(refreshToken)
    }

    /// 対話的 PKCE 認可。ブラウザを開きログイン → 認可コード受領 → トークン交換 → refresh 保管。
    public func authorize() async throws {
        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
        ]
        let authorizeURL = components.url!
        await MainActor.run { _ = NSWorkspace.shared.open(authorizeURL) }

        let code = try await LoopbackServer().waitForCode(port: loopbackPort)

        let token = try await requestToken(params: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectUri,
            "client_id": clientId,
            "code_verifier": verifier,
        ])
        apply(token)
        if let refresh = token.refreshToken {
            store.save(refresh)
        }
    }

    private func refreshAccessToken(_ refreshToken: String) async throws -> String {
        let token = try await requestToken(params: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ])
        apply(token)
        if let refresh = token.refreshToken {
            store.save(refresh)
        }
        return token.accessToken
    }

    private func apply(_ token: TokenResponse) {
        accessToken = token.accessToken
        expiry = clock.now.addingTimeInterval(Double(token.expiresIn) - 30)
    }

    private func requestToken(params: [String: String]) async throws -> TokenResponse {
        let url = URL(string: "https://accounts.spotify.com/api/token")!
        do {
            let data = try await http.post(
                url: url,
                body: Self.formEncode(params),
                headers: ["Content-Type": "application/x-www-form-urlencoded"]
            )
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(TokenResponse.self, from: data)
        } catch {
            throw SpotifyError.authFailed(String(describing: error))
        }
    }

    static func formEncode(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = params.map { key, value -> String in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
    }
}
