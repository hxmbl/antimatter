import Foundation
import Network

/// Loopback-only HTTP control plane for the Raycast extension.
/// Reachable only on 127.0.0.1.
///
///   GET /ping                  → {"ok": true}
///   GET /command?line=.timer 5 → {"ok": true, "message": "Timer 5 min — …"}
///   GET /note?text=hello       → {"ok": true, "message": "New note — …"}
///   GET /append?text=more      → {"ok": true, "message": "Appended"}
///
/// Ports are probed in order so a stray process squatting on 41367 doesn't
/// wedge the app; the extension mirrors the same list.
///
/// Only native clients may talk to this listener. That is enforced by *not*
/// serving browsers rather than by an `Origin` allow-list: `GET` with no custom
/// headers is a CORS **simple request**, so `<img src>`, `<script src>` and
/// `no-cors fetch` send no `Origin` at all and an `Origin` check alone stopped
/// nothing. `Sec-Fetch-Site`, by contrast, is attached by every current browser
/// to every request and is sent by no native client — so its mere presence
/// identifies the caller as a web page, which is exactly the thing to refuse.
/// `Host` is validated too, so a rebound DNS name can't aim at the port.
@MainActor
final class LocalBridge {
    static let shared = LocalBridge()

    /// `[port]` in probe order; must match `src/lib/antimatter.ts` in the extension.
    nonisolated static let candidatePorts: [UInt16] = [41_367, 41_368, 41_369]

    /// Hosts this listener answers to. `127.0.0.1` in any spelling AppKit's URL
    /// parser produces; anything else is a rebound or proxied name.
    nonisolated static let acceptedHosts: Set<String> = [
        "127.0.0.1", "localhost", "[::1]", "::1"
    ]

    private(set) var activePort: UInt16?

    /// Set once a listener has actually reached `.ready`. `NWListener`
    /// initialises successfully even when the bind will fail — the failure only
    /// arrives later, on `start(queue:)` — so reporting a port before then is a
    /// lie, and a harmful one: the port belongs to whoever *did* bind it, so
    /// every Raycast command would be executed by a different process while this
    /// one believed it was serving them. Callers must gate on this, not on
    /// `activePort`.
    private(set) var isReady = false

    private var listener: NWListener?
    private var ports: [UInt16] = LocalBridge.candidatePorts
    private let queue = DispatchQueue(label: "com.stormofthoughts.antimatter.bridge")

    /// `ports` is injectable so tests can bind a port they know is free rather
    /// than one a real running copy of the app already owns — which is exactly
    /// what made this suite test *another process*.
    func start(ports candidatePorts: [UInt16]? = nil) {
        guard listener == nil else { return }
        self.ports = candidatePorts ?? Self.candidatePorts
        isReady = false
        var chosen: (listener: NWListener, port: UInt16)?
        for port in ports where !claimedPorts.contains(port) {
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
            chosen = (candidate, port)
            break
        }
        guard let chosen else {
            DebugLog.log("bridge unavailable — no candidate port could be prepared")
            return
        }

        let listener = chosen.listener
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Report the port the kernel actually gave us. That matters when
                // the requested port was 0 ("any free port"), which is how a
                // caller that must not collide with another instance — the test
                // suite — asks for a listener without having to guess a free port
                // and then race another process for it.
                let bound = listener.port?.rawValue ?? chosen.port
                // Copy the weak reference into a fresh immutable local: the
                // stored handler must keep capturing `self` weakly (a strong
                // capture here would cycle self → listener → handler → self),
                // and the Tasks below need an immutable binding to capture.
                let owner = self
                Task { @MainActor in
                    guard let owner, owner.listener === listener else { return }
                    owner.activePort = bound
                    owner.isReady = true
                    DebugLog.log("bridge listening on 127.0.0.1:\(bound)")
                }
            case .failed(let error):
                let owner = self
                Task { @MainActor in
                    guard let owner, owner.listener === listener else { return }
                    owner.isReady = false
                    owner.activePort = nil
                    owner.listener = nil
                    owner.claimedPorts.insert(chosen.port)
                    DebugLog.log("bridge failed to bind 127.0.0.1:\(chosen.port) — \(error.localizedDescription)")
                }
            case .cancelled:
                let owner = self
                Task { @MainActor in
                    guard let owner, owner.listener === listener else { return }
                    owner.isReady = false
                    owner.activePort = nil
                    owner.listener = nil
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { @MainActor in self.accept(connection) }
        }
        listener.start(queue: queue)
    }

    /// Ports already found to be taken this session. `NWListener` reports the
    /// bind failure asynchronously, long after `start()` returned, so without
    /// this a port that is genuinely occupied is retried on every `start()`
    /// and the app burns through its list instead of walking past it.
    private var claimedPorts: Set<UInt16> = []

    /// The port to advertise, or nil until the listener is genuinely ready.
    var readyPort: UInt16? { isReady ? activePort : nil }

    func stop() {
        listener?.cancel()
        listener = nil
        activePort = nil
        isReady = false
        ports = Self.candidatePorts
        claimedPorts.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, accumulated: Data())
    }

    /// A request may arrive split across TCP segments — loopback does not
    /// guarantee that one `receive` sees it whole, and the old single-shot
    /// receive truncated such requests mid-URL (the extension's command then
    /// failed or ran with a cut argument). Accumulate until the header block
    /// is complete instead. GET-only protocol: nothing after the blank line
    /// matters, and the byte cap bounds memory for a client that streams
    /// forever. An idle connection behaves exactly as before — `receive`
    /// stays pending until data or EOF arrives either way.
    private nonisolated static let maxRequestBytes = 1_048_576

    /// Pure state machine on the connection's queue — no shared state, so it
    /// is `nonisolated` and every terminal path hops to the MainActor once.
    private nonisolated func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
            var next = accumulated
            if let data, !data.isEmpty { next.append(data) }
            let payload = next
            let hasHeader = payload.range(of: Data("\r\n\r\n".utf8)) != nil
            guard let self else {
                connection.cancel()
                return
            }
            if hasHeader || payload.count > Self.maxRequestBytes || isComplete {
                // Header complete, cap exceeded, or the client hung up with
                // an incomplete request: answer with what arrived — the
                // single-shot behaviour the truncated case used to get.
                Task { @MainActor in self.respond(connection, request: payload) }
                return
            }
            self.receiveRequest(connection, accumulated: payload)
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        Task { @MainActor in
            let response = self.response(for: request)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    @MainActor
    private func response(for request: Data) -> Data {
        let text = String(decoding: request, as: UTF8.self)
        let headerLines = text.split(separator: "\r\n")
        let requestLine = headerLines.first ?? ""

        // Refuse browsers first. `Sec-Fetch-Site` is attached by every current browser
        // to every request — including the CORS-simple `<img src>` / `<script
        // src>` / `no-cors fetch` shapes that carry **no** `Origin` at all, which
        // is why the old `Origin` allow-list stopped nothing. No native client
        // sends it, so its presence identifies the caller as a web page.
        let fetchSite = headerLines.first { $0.lowercased().hasPrefix("sec-fetch-site:") }
        guard fetchSite == nil else {
            return httpResponse(status: "403 Forbidden",
                                body: Data("{\"ok\":false,\"message\":\"Browser requests are not accepted\"}".utf8))
        }
        // Second gate, kept because it is free and independently useful.
        if let origin = headerLines.first(where: { $0.lowercased().hasPrefix("origin:") }) {
            let value = String(origin.dropFirst("origin:".count)).trimmingCharacters(in: .whitespaces)
            guard value.lowercased() == "null" else {
                return httpResponse(status: "403 Forbidden",
                                    body: Data("{\"ok\":false,\"message\":\"Origin not allowed\"}".utf8))
            }
        }
        // A rebound DNS name could aim a non-browser client at the port.
        if let hostHeader = headerLines.first(where: { $0.lowercased().hasPrefix("host:") }) {
            let value = String(hostHeader.dropFirst("host:".count))
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let bare = value.hasPrefix("[")
                ? String(value.prefix(while: { $0 != "]" }) + "]")
                : value.components(separatedBy: ":").first ?? value
            guard Self.acceptedHosts.contains(bare) else {
                return httpResponse(status: "403 Forbidden",
                                    body: Data("{\"ok\":false,\"message\":\"Unexpected host\"}".utf8))
            }
        }
        // Only ever GET. Nothing here needs another verb, and accepting a
        // body-bearing verb widens the drive-by surface for no benefit.
        guard requestLine.hasPrefix("GET ") else {
            return httpResponse(status: "405 Method Not Allowed",
                                body: Data("{\"ok\":false,\"message\":\"GET only\"}".utf8))
        }

        let tokens = requestLine.split(separator: " ")
        let target = tokens.count > 1 ? String(tokens[1]) : "/"
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
            guard DeepLinkRouter.isSafeCommand(line) else {
                return httpResponse(status: "403 Forbidden",
                                    body: Data("{\"ok\":false,\"message\":\"Command not allowed via bridge\"}".utf8))
            }
            outcome = ActionRunner.run(line)
        case "/note":
            let text = query?.queryItems?.first { $0.name == "text" }?.value ?? ""
            guard DeepLinkRouter.isSafeCommand(text) else {
                return httpResponse(status: "403 Forbidden",
                                    body: Data("{\"ok\":false,\"message\":\"Command not allowed via bridge\"}".utf8))
            }
            outcome = ActionRunner.create(text: text)
        case "/append":
            let text = query?.queryItems?.first { $0.name == "text" }?.value ?? ""
            guard DeepLinkRouter.isSafeCommand(text) else {
                return httpResponse(status: "403 Forbidden",
                                    body: Data("{\"ok\":false,\"message\":\"Command not allowed via bridge\"}".utf8))
            }
            outcome = ActionRunner.append(text: text)
        default:
            outcome = ActionOutcome(ok: false, message: "Unknown endpoint \(path)")
        }

        var body = Data("{\"ok\":false}".utf8)
        if let encoded = try? JSONEncoder().encode(outcome) {
            body = encoded
        }
        return httpResponse(status: "200 OK", body: body)
    }

    private func httpResponse(status: String, body: Data) -> Data {
        var headers = "HTTP/1.1 \(status)\r\n"
        headers += "Content-Type: application/json\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        headers += "Connection: close\r\n\r\n"
        return Data(headers.utf8) + body
    }
}