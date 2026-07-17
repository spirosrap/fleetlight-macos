import Foundation
import Network

final class MobileFeedHTTPServer: @unchecked Sendable {
    static let shared = MobileFeedHTTPServer()

    private let queue = DispatchQueue(label: "Fleetlight.MobileFeedHTTPServer", qos: .utility)
    private var listener: NWListener?

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self, listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: NWEndpoint.Port(rawValue: 8_787)!
                )
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state {
                        self?.listener?.cancel()
                        self?.listener = nil
                    }
                }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                listener = nil
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var request = buffer
            if let data { request.append(data) }
            if request.count > 8_192 {
                respond(status: "413 Payload Too Large", body: Data(), contentType: "text/plain", on: connection)
                return
            }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                handle(request, on: connection)
            } else if error == nil {
                receiveRequest(on: connection, buffer: request)
            } else {
                connection.cancel()
            }
        }
    }

    private func handle(_ request: Data, on connection: NWConnection) {
        guard let requestText = String(data: request, encoding: .utf8),
              let requestLine = requestText.components(separatedBy: "\r\n").first else {
            respond(status: "400 Bad Request", body: Data(), contentType: "text/plain", on: connection)
            return
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            respond(status: "400 Bad Request", body: Data(), contentType: "text/plain", on: connection)
            return
        }
        guard parts[0] == "GET" else {
            respond(status: "405 Method Not Allowed", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        let path = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? parts[1]
        switch path {
        case "/mobile-feed.json", "/fleetlight/mobile-feed.json":
            guard let data = try? Data(contentsOf: MobileFeedStore.feedURL) else {
                respond(
                    status: "503 Service Unavailable",
                    body: Data(#"{"status":"waiting"}"#.utf8),
                    contentType: "application/json",
                    on: connection
                )
                return
            }
            respond(status: "200 OK", body: data, contentType: "application/json", on: connection)
        case "/health", "/fleetlight/health":
            respond(
                status: "200 OK",
                body: Data(#"{"status":"ok"}"#.utf8),
                contentType: "application/json",
                on: connection
            )
        default:
            respond(status: "404 Not Found", body: Data(), contentType: "text/plain", on: connection)
        }
    }

    private func respond(
        status: String,
        body: Data,
        contentType: String,
        on connection: NWConnection
    ) {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType); charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(
            content: response,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else {
                    connection.cancel()
                    return
                }
                // Keep the connection alive long enough for Network.framework
                // to drain the final TCP bytes before releasing our reference.
                self.queue.asyncAfter(deadline: .now() + 30) {
                    connection.cancel()
                }
            }
        )
    }
}
