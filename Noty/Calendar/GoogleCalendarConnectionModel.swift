import AppKit
import Combine
import Foundation

/// Drives the Settings sign-in: opens the default browser, receives the loopback redirect,
/// and reports connection state.
@MainActor
final class GoogleCalendarConnectionModel: ObservableObject {
    @Published private(set) var isConnected: Bool
    @Published private(set) var isConnecting = false
    @Published private(set) var errorMessage: String?

    let account: GoogleCalendarAccount

    init(account: GoogleCalendarAccount) {
        self.account = account
        isConnected = account.isConnected
    }

    var isConfigured: Bool {
        account.configuration != nil
    }

    func connect() async {
        guard !isConnecting else { return }
        guard account.configuration != nil else {
            errorMessage = GoogleCalendarError.notConfigured.localizedDescription
            return
        }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let request = GoogleOAuthCodeRequest.make()
        let listener = LoopbackRedirectListener()
        defer { listener.cancel() }
        do {
            let port = try await listener.start()
            let redirectURI = "http://127.0.0.1:\(port)/"
            let url = try await account.authorizationURL(for: request, redirectURI: redirectURI)
            guard NSWorkspace.shared.open(url) else { throw GoogleCalendarError.browserUnavailable }
            let redirect = try await listener.awaitRedirect()
            let code = try GoogleOAuthRedirect.authorizationCode(from: redirect, expectedState: request.state)
            try await account.completeAuthorization(code: code, request: request, redirectURI: redirectURI)
            isConnected = account.isConnected
        } catch GoogleCalendarError.authorizationCancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() async {
        do {
            try await account.disconnect()
            isConnected = account.isConnected
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
