import Foundation
import Network

/// Loopback-only HTTP control plane that gives the Raycast extension (and
/// anything else on this machine) a request/response channel into the app —
/// the URL scheme alone is fire-and-forget, so command outcomes (a started
/// timer's real duration, a computed aggregate) could never come back.
///
/// Reachable only on 127.0.0.1, so no firewall prompt and nothing leaves the
/// machine; the extension probes `/ping` to learn when the app is ready,
/// then calls the action endpoints:
///
///   GET /ping                  → {"ok": true}
///   GET /command?line=.timer 5 → {"ok": true, "message": "Timer 5 min — …"}
///   GET /note?text=hello       → {"ok": true, "message": "New note — …"}
///   GET /append?text=more      → {"ok": true, "message": "Appended"}
///
/// Ports are probed in order so a stray process squatting on 41367 doesn't
/// wedge the app; the extension mirrors the same list.
@MainActor
final class LocalBridge {
    static let shared = LocalBridge()

    /// `[port]` in probe order; must match `src/lib/api.ts` in the extension.
    nonisolated static let candidatePorts: [UInt16] = [41_367, 41_368, 41_369]

    private(set) var activePort: UInt16?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.stormofthoughts.antimatter.bridge")

    func start() {
        guard listener == nil else { return }
        for port in Self.candidatePorts {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // A listener's fixed port comes from requiredLocalEndpoint, so the
            // `on:` slot must request an ephemeral port — passing both an explicit
            // `on:` port triggers EINVAL. This binds exactly 127.0.0.1:port.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!
            )
            let candidate = try? NWListener(using: parameters, on: 0)
            guard let candidate else { continue }
            listener = candidate
            activePort = port
            break
        }
        guard let listener else { return }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activePort = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                let response = self.response(for: data)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
            _ = isComplete
        }
    }

    @MainActor
    private func response(for request: Data) -> Data {
        let text = String(decoding: request, as: UTF8.self)
        let requestLine = text.split(separator: "\r\n").first ?? ""
        let tokens = requestLine.split(separator: " ")
        let target = tokens.count > 1 ? tokens[1] : "/"
        // Form-encoded clients send spaces as `+`; URLComponents leaves `+`
        // literal, so translate it to `%20` before the generic parse.
        let normalized = target.replacingOccurrences(of: "+", with: "%20")
        let url = URL(string: "http://127.0.0.1" + normalized)
        let path = url?.path ?? ""
        let query = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }

        let outcome: ActionOutcome
        switch path {
        case "/ping":
            outcome = ActionOutcome(ok: true, message: "")
        case "/command":
            let line = query?.queryItems?.first { $0.name == "line" }?.value ?? ""
            outcome = ActionRunner.run(line)
        case "/note":
            let text = query?.queryItems?.first { $0.name == "text" }?.value ?? ""
            outcome = ActionRunner.create(text: text)
        case "/append":
            let text = query?.queryItems?.first { $0.name == "text" }?.value ?? ""
            outcome = ActionRunner.append(text: text)
        default:
            outcome = ActionOutcome(ok: false, message: "Unknown endpoint \(path)")
        }

        var body: Data = Data("{\"ok\":false}".utf8)
        if let encoded = try? JSONEncoder().encode(outcome) {
            body = encoded
        }
        var headers = "HTTP/1.1 200 OK\r\n"
        headers += "Content-Type: application/json\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        headers += "Connection: close\r\n\r\n"
        return Data(headers.utf8) + body
    }
}