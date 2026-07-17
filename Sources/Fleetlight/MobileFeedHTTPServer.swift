import Foundation
import FleetlightCore
import Network

final class MobileFeedHTTPServer: @unchecked Sendable {
    private enum ListenerRole: Sendable, Equatable {
        case feedAndControl
        case localPairing
    }

    static let shared = MobileFeedHTTPServer()

    private let queue = DispatchQueue(label: "Fleetlight.MobileFeedHTTPServer", qos: .utility)
    private var listener: NWListener?
    private var localPairingListener: NWListener?
    private var controlHandler: (@Sendable (MobileControlHTTPRequest) async -> MobileControlHTTPResponse)?
    private var localPairingHandler: (@Sendable (MobileControlHTTPRequest) async -> MobileControlHTTPResponse)?

    private init() {}

    func start(
        controlHandler: @escaping @Sendable (MobileControlHTTPRequest) async -> MobileControlHTTPResponse,
        localPairingHandler: @escaping @Sendable (MobileControlHTTPRequest) async -> MobileControlHTTPResponse
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.controlHandler = controlHandler
            self.localPairingHandler = localPairingHandler
            if listener == nil {
                listener = makeListener(port: 8_787, role: .feedAndControl)
                listener?.stateUpdateHandler = { [weak self] state in
                    if case .failed = state {
                        self?.listener?.cancel()
                        self?.listener = nil
                    }
                }
                listener?.start(queue: queue)
            }
            if localPairingListener == nil {
                localPairingListener = makeListener(port: 8_788, role: .localPairing)
                localPairingListener?.stateUpdateHandler = { [weak self] state in
                    if case .failed = state {
                        self?.localPairingListener?.cancel()
                        self?.localPairingListener = nil
                    }
                }
                localPairingListener?.start(queue: queue)
            }
        }
    }

    private func makeListener(port: UInt16, role: ListenerRole) -> NWListener? {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: port)!
            )
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, role: role)
            }
            return listener
        } catch {
            return nil
        }
    }

    private func accept(_ connection: NWConnection, role: ListenerRole) {
        connection.start(queue: queue)
        receiveRequest(on: connection, role: role, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, role: ListenerRole, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var request = buffer
            if let data { request.append(data) }
            if request.count > MobileControlHTTPRequestParser.maximumRequestBytes {
                respond(status: "413 Payload Too Large", body: Data(), contentType: "text/plain", on: connection)
                return
            }
            switch MobileControlHTTPRequestParser.parse(request) {
            case .incomplete where error == nil && !isComplete:
                receiveRequest(on: connection, role: role, buffer: request)
            case .incomplete:
                respond(status: "400 Bad Request", body: Data(), contentType: "text/plain", on: connection)
            case let .failure(parseError):
                let status = switch parseError {
                case .headersTooLarge, .bodyTooLarge: "413 Payload Too Large"
                case .unsupportedTransferEncoding: "501 Not Implemented"
                case .malformedRequest: "400 Bad Request"
                }
                respond(status: status, body: Data(), contentType: "text/plain", on: connection)
            case let .complete(parsedRequest):
                handle(parsedRequest, role: role, on: connection)
            }
        }
    }

    private func handle(_ request: MobileControlHTTPRequest, role: ListenerRole, on connection: NWConnection) {
        if role == .localPairing {
            guard request.path == "/pairing/start", let localPairingHandler else {
                respond(status: "404 Not Found", body: Data(), contentType: "text/plain", on: connection)
                return
            }
            Task {
                let response = await localPairingHandler(request)
                respond(
                    status: "\(response.statusCode) \(response.reason)",
                    body: response.body,
                    contentType: response.contentType,
                    on: connection
                )
            }
            return
        }

        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        switch path {
        case "/mobile-feed.json", "/fleetlight/mobile-feed.json":
            guard request.method == "GET" else {
                respond(status: "405 Method Not Allowed", body: Data(), contentType: "text/plain", on: connection)
                return
            }
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
            guard request.method == "GET" else {
                respond(status: "405 Method Not Allowed", body: Data(), contentType: "text/plain", on: connection)
                return
            }
            respond(
                status: "200 OK",
                body: Data(#"{"status":"ok"}"#.utf8),
                contentType: "application/json",
                on: connection
            )
        default:
            guard isControlPath(path), let controlHandler else {
                respond(status: "404 Not Found", body: Data(), contentType: "text/plain", on: connection)
                return
            }
            Task {
                let response = await controlHandler(request)
                respond(
                    status: "\(response.statusCode) \(response.reason)",
                    body: response.body,
                    contentType: response.contentType,
                    on: connection
                )
            }
        }
    }

    private func isControlPath(_ path: String) -> Bool {
        path == "/control/v1"
            || path.hasPrefix("/control/v1/")
            || path == "/fleetlight/control/v1"
            || path.hasPrefix("/fleetlight/control/v1/")
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
