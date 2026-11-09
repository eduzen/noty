import Foundation

/// OAuth client values copied into Info.plist from `Config/Google.local.xcconfig`.
struct GoogleCalendarConfiguration: Equatable, Sendable {
    private static let clientSuffix = ".apps.googleusercontent.com"
    private static let reversedPrefix = "com.googleusercontent.apps."

    let clientID: String
    let redirectScheme: String

    /// Returns nil unless the reversed client ID is the reverse of the client ID.
    init?(clientID: String, reversedClientID: String) {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = reversedClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(Self.clientSuffix) else { return nil }
        let numericPart = String(id.dropLast(Self.clientSuffix.count))
        guard !numericPart.isEmpty, scheme == Self.reversedPrefix + numericPart else { return nil }
        self.clientID = id
        redirectScheme = scheme
    }

    static func fromBundle(_ bundle: Bundle = .main) -> GoogleCalendarConfiguration? {
        guard let clientID = bundle.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String,
              let reversed = bundle.object(forInfoDictionaryKey: "GoogleOAuthReversedClientID") as? String
        else { return nil }
        return GoogleCalendarConfiguration(clientID: clientID, reversedClientID: reversed)
    }

    /// Google's iOS-client redirect uses the reversed client ID as the scheme, with no host.
    var redirectURI: String {
        "\(redirectScheme):/oauth2redirect"
    }
}
