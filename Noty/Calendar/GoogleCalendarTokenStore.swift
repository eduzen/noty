import Foundation
import Security

/// Holds the long-lived Google refresh token. Access tokens are never stored.
protocol GoogleCalendarTokenStoring: Sendable {
    func refreshToken() -> String?
    func saveRefreshToken(_ token: String) throws
    func deleteRefreshToken() throws
}

struct KeychainGoogleCalendarTokenStore: GoogleCalendarTokenStoring {
    private let service = "com.eduzen.noty.google-calendar"
    private let account = "refresh-token"

    func refreshToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveRefreshToken(_ token: String) throws {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw GoogleCalendarError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw GoogleCalendarError.keychain(updateStatus)
        }
    }

    func deleteRefreshToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleCalendarError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
