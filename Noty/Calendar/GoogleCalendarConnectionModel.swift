import AppKit
import AuthenticationServices
import Combine
import Foundation

/// Drives the Settings sign-in: runs the browser session and reports connection state.
@MainActor
final class GoogleCalendarConnectionModel: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var isConnected: Bool
    @Published private(set) var isConnecting = false
    @Published private(set) var errorMessage: String?

    let account: GoogleCalendarAccount
    private var authorizationSession: ASWebAuthenticationSession?

    init(account: GoogleCalendarAccount) {
        self.account = account
        isConnected = account.isConnected
        super.init()
    }

    var isConfigured: Bool {
        account.configuration != nil
    }

    func connect() async {
        guard !isConnecting else { return }
        guard let configuration = account.configuration else {
            errorMessage = GoogleCalendarError.notConfigured.localizedDescription
            return
        }
        isConnecting = true
        errorMessage = nil
        defer {
            isConnecting = false
            authorizationSession = nil
        }
        let request = GoogleOAuthCodeRequest.make()
        do {
            let url = try await account.authorizationURL(for: request)
            let callbackURL = try await runAuthorizationSession(url: url, callbackScheme: configuration.redirectScheme)
            try await account.completeAuthorization(callbackURL: callbackURL, request: request)
            isConnected = account.isConnected
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
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

    private func runAuthorizationSession(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? GoogleCalendarError.authorizationFailed)
                }
            }
            session.presentationContextProvider = self
            authorizationSession = session
            if !session.start() {
                continuation.resume(throwing: GoogleCalendarError.authorizationFailed)
            }
        }
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
