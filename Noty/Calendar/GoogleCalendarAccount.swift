import CryptoKit
import Foundation

enum GoogleCalendarError: Error, Equatable, LocalizedError {
    case notConfigured
    case notConnected
    case authorizationFailed
    case invalidResponse
    case requestFailed(statusCode: Int)
    case tokenRevoked
    case authorizationCancelled
    case authorizationTimedOut
    case browserUnavailable
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google Calendar needs an OAuth client ID in Config/Google.local.xcconfig."
        case .notConnected:
            return "Google Calendar is not connected."
        case .authorizationFailed:
            return "Google did not finish signing in. Try connecting again."
        case .authorizationCancelled:
            return "Google sign-in was cancelled."
        case .authorizationTimedOut:
            return "Google sign-in timed out. Try connecting again."
        case .browserUnavailable:
            return "Noty could not open your browser for Google sign-in."
        case .invalidResponse:
            return "Google Calendar returned an unexpected response."
        case let .requestFailed(statusCode):
            return "Google Calendar request failed with status \(statusCode)."
        case .tokenRevoked:
            return "Google Calendar access was revoked. Connect again."
        case let .keychain(status):
            return "Noty could not save the Google Calendar sign-in (Keychain status \(status))."
        }
    }
}

/// PKCE verifier and CSRF state for one authorization attempt.
struct GoogleOAuthCodeRequest: Equatable, Sendable {
    let codeVerifier: String
    let state: String

    var codeChallenge: String {
        Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncodedString()
    }

    static func make() -> GoogleOAuthCodeRequest {
        GoogleOAuthCodeRequest(codeVerifier: randomBase64URL(byteCount: 32),
                               state: randomBase64URL(byteCount: 16))
    }
}

/// Owns the Google session: exchanges the authorization code, stores the refresh token,
/// and hands out short-lived access tokens with one refresh in flight at a time.
actor GoogleCalendarAccount {
    static let scope = "https://www.googleapis.com/auth/calendar.events.readonly"
    private static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let refreshMargin: TimeInterval = 60

    nonisolated let configuration: GoogleCalendarConfiguration?
    nonisolated let session: URLSession
    private let tokens: GoogleCalendarTokenStoring
    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var refreshTask: Task<String, Error>?

    init(configuration: GoogleCalendarConfiguration? = GoogleCalendarConfiguration.fromBundle(),
         tokens: GoogleCalendarTokenStoring = KeychainGoogleCalendarTokenStore(),
         session: URLSession = .shared) {
        self.configuration = configuration
        self.tokens = tokens
        self.session = session
    }

    nonisolated var isConnected: Bool {
        tokens.refreshToken() != nil
    }

    /// `redirectURI` is the loopback address of the local listener, for example `http://127.0.0.1:50123/`.
    func authorizationURL(for request: GoogleOAuthCodeRequest, redirectURI: String) throws -> URL {
        guard let configuration else { throw GoogleCalendarError.notConfigured }
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: request.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: request.state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let url = components?.url else { throw GoogleCalendarError.invalidResponse }
        return url
    }

    /// Exchanges an authorization code the listener already validated, then stores the refresh token.
    func completeAuthorization(code: String, request: GoogleOAuthCodeRequest, redirectURI: String) async throws {
        guard let configuration else { throw GoogleCalendarError.notConfigured }
        let response = try await requestToken(withSecret(configuration, [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": request.codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]))
        guard let refreshToken = response.refreshToken else { throw GoogleCalendarError.authorizationFailed }
        try tokens.saveRefreshToken(refreshToken)
        cache(response)
    }

    /// Returns a cached access token, or refreshes it. Concurrent callers share one refresh.
    func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(Self.refreshMargin) {
            return accessToken
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task { try await self.refreshAccessToken() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func disconnect() throws {
        accessToken = nil
        accessTokenExpiry = .distantPast
        try tokens.deleteRefreshToken()
    }

    private func refreshAccessToken() async throws -> String {
        guard let configuration else { throw GoogleCalendarError.notConfigured }
        guard let refreshToken = tokens.refreshToken() else { throw GoogleCalendarError.notConnected }
        do {
            let response = try await requestToken(withSecret(configuration, [
                "client_id": configuration.clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ]))
            cache(response)
            return response.accessToken
        } catch GoogleCalendarError.tokenRevoked {
            try? tokens.deleteRefreshToken()
            accessToken = nil
            throw GoogleCalendarError.notConnected
        }
    }

    private func cache(_ response: TokenResponse) {
        accessToken = response.accessToken
        accessTokenExpiry = Date().addingTimeInterval(response.expiresIn)
    }

    private func requestToken(_ parameters: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = Data(formBody(parameters).utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let failure = try? JSONDecoder().decode(TokenErrorResponse.self, from: data),
               failure.error == "invalid_grant" {
                throw GoogleCalendarError.tokenRevoked
            }
            throw GoogleCalendarError.requestFailed(statusCode: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GoogleCalendarError.invalidResponse
        }
    }

    private func formBody(_ parameters: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
            }
            .joined(separator: "&")
    }

    private func withSecret(_ configuration: GoogleCalendarConfiguration, _ parameters: [String: String])
        -> [String: String] {
        guard let secret = configuration.clientSecret else { return parameters }
        var merged = parameters
        merged["client_secret"] = secret
        return merged
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?
}

private struct TokenErrorResponse: Decodable {
    let error: String
}

private func randomBase64URL(byteCount: Int) -> String {
    let bytes = (0 ..< byteCount).map { _ in UInt8.random(in: UInt8.min ... UInt8.max) }
    return Data(bytes).base64URLEncodedString()
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
