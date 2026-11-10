import Foundation

/// OAuth Desktop-client values copied into Info.plist from `Config/Google.local.xcconfig`.
struct GoogleCalendarConfiguration: Equatable, Sendable {
    private static let clientSuffix = ".apps.googleusercontent.com"

    let clientID: String
    /// Google's Desktop-client token exchange expects this value. It is not a secret for installed apps.
    let clientSecret: String?

    /// Returns nil unless the client ID has the Google OAuth client format.
    init?(clientID: String, clientSecret: String?) {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(Self.clientSuffix), id.count > Self.clientSuffix.count else { return nil }
        self.clientID = id
        let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = (secret?.isEmpty ?? true) ? nil : secret
    }

    static func fromBundle(_ bundle: Bundle = .main) -> GoogleCalendarConfiguration? {
        guard let clientID = bundle.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String else {
            return nil
        }
        let clientSecret = bundle.object(forInfoDictionaryKey: "GoogleOAuthClientSecret") as? String
        return GoogleCalendarConfiguration(clientID: clientID, clientSecret: clientSecret)
    }
}
