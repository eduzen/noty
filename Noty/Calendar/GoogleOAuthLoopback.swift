import Foundation
import Network

/// Reads Google's redirect to the loopback listener and checks it belongs to this attempt.
enum GoogleOAuthRedirect {
    /// Returns the authorization code, or throws when the redirect reports an error or has the wrong state.
    static func authorizationCode(from url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        if let error = value("error") {
            throw error == "access_denied"
                ? GoogleCalendarError.authorizationCancelled
                : GoogleCalendarError.authorizationFailed
        }
        guard value("state") == expectedState, let code = value("code") else {
            throw GoogleCalendarError.authorizationFailed
        }
        return code
    }
}

/// Accepts one OAuth redirect on the loopback interface, then stops listening.
/// All mutable state is confined to `queue`.
final class LoopbackRedirectListener: @unchecked Sendable {
    private static let timeout: DispatchTimeInterval = .seconds(180)

    private let queue = DispatchQueue(label: "com.eduzen.noty.oauth-loopback")
    private var listener: NWListener?
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var redirectWaiter: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?

    /// Starts listening on an ephemeral loopback port and returns that port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startWaiter = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredInterfaceType = .loopback
                    let listener = try NWListener(using: parameters)
                    listener.stateUpdateHandler = { [weak self] state in self?.handle(state: state) }
                    listener.newConnectionHandler = { [weak self] connection in self?.handle(connection: connection) }
                    self.listener = listener
                    listener.start(queue: self.queue)
                } catch {
                    self.startWaiter?.resume(throwing: error)
                    self.startWaiter = nil
                }
            }
        }
    }

    /// Waits for Google to redirect the browser to this listener. Fails after the timeout.
    func awaitRedirect() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let outcome = self.outcome {
                    continuation.resume(with: outcome)
                    return
                }
                self.redirectWaiter = continuation
                self.queue.asyncAfter(deadline: .now() + Self.timeout) {
                    self.finish(.failure(GoogleCalendarError.authorizationTimedOut))
                }
            }
        }
    }

    /// Stops listening and fails a pending wait. Safe to call more than once.
    func cancel() {
        queue.async {
            self.finish(.failure(CancellationError()))
        }
    }

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            startWaiter?.resume(returning: port)
            startWaiter = nil
        case let .failed(error):
            startWaiter?.resume(throwing: error)
            startWaiter = nil
            finish(.failure(error))
        default:
            break
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let redirect = data.flatMap(Self.redirectURL(fromRequest:))
            let status = redirect == nil ? "404 Not Found" : "200 OK"
            let body = redirect == nil
                ? "<html><body>Not found.</body></html>"
                : "<html><body><p>Google sign-in finished. You can close this tab and return to Noty.</p></body></html>"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
                if let redirect {
                    self.finish(.success(redirect))
                }
            })
        }
    }

    /// Returns the request target as a URL when it is a GET carrying an OAuth `code` or `error`.
    private static func redirectURL(fromRequest data: Data) -> URL? {
        guard let text = String(data: data, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first
        else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let url = URL(string: "http://127.0.0.1" + String(parts[1]))
        else { return nil }
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        return names.contains("code") || names.contains("error") ? url : nil
    }

    private func finish(_ result: Result<URL, Error>) {
        guard outcome == nil else { return }
        outcome = result
        redirectWaiter?.resume(with: result)
        redirectWaiter = nil
        listener?.cancel()
        listener = nil
    }
}
