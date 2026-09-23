import Foundation
import Network

/// Minimal loopback HTTP server used to catch the OAuth redirect when the
/// configured redirect URI is `http://localhost:<port>/...` rather than a
/// custom URL scheme. Handles exactly one request, then can be reused for a
/// subsequent `start()`.
final class LocalOAuthCallbackServer: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "app.live-dashboard.assistant.oauth-callback")
    private var listener: NWListener?
    private var didFire = false
    private var didFail = false
    private let lock = NSLock()

    var onCallback: (@Sendable (URL) -> Void)?
    var onFailure: (@Sendable (Error) -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ChatGPTOAuthError.callbackServerUnavailable
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener: NWListener
        do {
            // The port already lives in `requiredLocalEndpoint`; passing it again
            // through `init(using:on:)` makes Network reject the listener.
            listener = try NWListener(using: parameters)
        } catch {
            throw ChatGPTOAuthError.callbackServerUnavailable
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.fireFailure(ChatGPTOAuthError.callbackServerUnavailable)
                self?.stop()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let requestLineRange = accumulated.range(of: Data("\r\n".utf8)),
               accumulated[..<requestLineRange.lowerBound].isEmpty == false {
                self.respondAndClose(connection: connection, data: accumulated)
                return
            }
            if isComplete || error != nil {
                if !accumulated.isEmpty {
                    self.respondAndClose(connection: connection, data: accumulated)
                } else {
                    connection.cancel()
                }
                return
            }
            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func respondAndClose(connection: NWConnection, data: Data) {
        defer {
            let html = "<html><body>\(String(localized: "登录成功，请返回 Live Dashboard。", bundle: .kit))</body></html>"
            let body = Data(html.utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var responseData = Data(response.utf8)
            responseData.append(body)
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        guard let firstLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return }
        let components = firstLine.split(separator: " ")
        guard components.count >= 2, components[0] == "GET" else { return }
        let path = String(components[1])
        guard let url = URL(string: "http://localhost:\(port)\(path)") else { return }
        fireCallback(url)
    }

    private func fireCallback(_ url: URL) {
        lock.lock()
        let alreadyFired = didFire
        didFire = true
        lock.unlock()
        guard !alreadyFired else { return }
        onCallback?(url)
    }

    private func fireFailure(_ error: Error) {
        lock.lock()
        let alreadyFailed = didFail
        didFail = true
        lock.unlock()
        guard !alreadyFailed else { return }
        onFailure?(error)
    }
}
