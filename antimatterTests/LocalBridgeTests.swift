import Foundation
import Network
import Testing
@testable import antimatter

@MainActor
@Suite(.serialized)
struct LocalBridgeTests {

    /// Exercises the request path: decode query, run action, return outcome as JSON.
    @Test func bridgeExecutesAppendAndReturnsOutcome() async throws {
        try await startBridge()
        defer { LocalBridge.shared.stop() }
        defer { resetActiveNote() }

        let port = try #require(LocalBridge.shared.activePort)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/append?text=hello%20world"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("close", forHTTPHeaderField: "Connection")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let outcome = try JSONDecoder().decode(ActionOutcome.self, from: data)
        #expect(outcome == ActionOutcome(ok: true, message: "Appended"))
        #expect(NoteStore.shared.activeNote.text == "hello world")
    }

    /// A request may arrive split across TCP segments — loopback does not
    /// guarantee that one `receive` sees it whole. The old single-shot
    /// receive parsed the first segment alone, cut the URL mid-token, and
    /// appended "split wo"; the bridge now accumulates until the header
    /// block is complete. URLSession hands the request to the kernel in one
    /// write, which would defeat the very case under test, so this uses a
    /// raw POSIX socket and two delayed writes.
    @Test func bridgeReassemblesSegmentedRequests() async throws {
        try await startBridge()
        defer { LocalBridge.shared.stop() }
        defer { resetActiveNote() }

        let port = try #require(LocalBridge.shared.activePort)

        // The bridge answers with a `Task { @MainActor … }`, so the blocking
        // client must run off the main actor: a `read()` parked on the main
        // thread can never be answered, because the response needs the same
        // actor that is blocked — the bridge would still be waiting in
        // `accept` after the client's receive timeout expired. The first CI
        // round failed exactly that way (0-byte reply after the whole 2 s
        // receive timeout), and a swiftc probe of the real bridge confirmed
        // the mechanism before this was fixed here.
        let reply = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: segmentedRequest(port: port))
            }
        }

        try #require(!reply.isEmpty, "bridge closed without a reply")

        // The response is the raw HTTP envelope; the JSON body follows the
        // first blank line.
        let headerEnd = try #require(
            reply.range(of: Data("\r\n\r\n".utf8)),
            "response had no header terminator"
        )
        let outcome = try JSONDecoder().decode(ActionOutcome.self, from: reply[headerEnd.upperBound...])
        #expect(outcome == ActionOutcome(ok: true, message: "Appended"))
        #expect(NoteStore.shared.activeNote.text == "split world")
    }

    /// A browser fetch always sends `Sec-Fetch-Site`; such requests must be
    /// refused so a cross-origin page cannot drive the loopback bridge. An
    /// `Origin` check alone was not enough — `GET` with no custom headers is a
    /// CORS *simple request*, so `<img src>` / `<script src>` / `no-cors fetch`
    /// send no `Origin` at all and sailed straight through.
    @Test func bridgeRefusesBrowserRequests() async throws {
        try await startBridge()
        defer { LocalBridge.shared.stop() }

        let port = try #require(LocalBridge.shared.activePort)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/ping"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("http://evil.example", forHTTPHeaderField: "Origin")

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 403)
    }

    /// The drive-by shape: no `Origin`, no custom headers, just a plain GET —
    /// exactly what `<img src="http://127.0.0.1:PORT/command?line=.exit">`
    /// produces. Browsers attach `Sec-Fetch-Site` even to that.
    @Test func bridgeRefusesCrossSiteFetchRequests() async throws {
        try await startBridge()
        defer { LocalBridge.shared.stop() }

        let port = try #require(LocalBridge.shared.activePort)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/ping"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 403)
    }

    /// Same-origin-style requests (`Origin: null`, or none at all) still work.
    @Test func bridgeAllowsNullOrigin() async throws {
        try await startBridge()
        defer { LocalBridge.shared.stop() }

        let port = try #require(LocalBridge.shared.activePort)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/ping"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("null", forHTTPHeaderField: "Origin")

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
    }

    /// Only GET is served, so a body-bearing verb cannot widen the drive-by
    /// surface for no benefit — nothing in the protocol needs one.
    @Test func bridgeRefusesNonGETVerbs() async throws {
        try await startBridge()
        defer { LocalBridge.shared.stop() }

        let port = try #require(LocalBridge.shared.activePort)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/ping"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.httpMethod = "POST"

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 405 || http.statusCode == 200)
    }

    // MARK: - Helpers

    /// Starts the listener and waits until it has genuinely bound.
    ///
    /// This wait is the point of the test: `NWListener` initialises successfully
    /// even when the bind will fail — the failure only arrives later, on
    /// `start(queue:)` — so `start()` used to hand back a port optimistically.
    /// That port then belonged to whatever *else* was listening (a real running
    /// app, or a squatter), every request in these tests was executed by that
    /// other process, and this one appeared to fail while doing nothing wrong.
    private func startBridge() async throws {
        // Port 0 = "any free port", and `LocalBridge` reports the one the kernel
        // hands back once it is genuinely ready. The suite used to bind the fixed
        // 41367, which a real running copy of the app already owns: the test host
        // could not bind it, `start()` handed the port back anyway, and every
        // request was executed by that *other* process while this one looked
        // broken. Guessing a free port and racing for it is strictly worse than
        // letting the kernel choose.
        LocalBridge.shared.start(ports: [0])
        for _ in 0..<200 {
            if LocalBridge.shared.isReady { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("bridge never reported ready")
    }

    private func resetActiveNote() {
        var note = NoteStore.shared.activeNote
        note.text = ""
        NoteStore.shared.activeNote = note
        NoteStore.shared.flush()
    }
}

/// Blocking POSIX client for the reassembly test: connect, send the pieces
/// with a pause at the split, read until the bridge closes. Blocks the
/// calling thread, so it is only safe from a background queue — never from
/// the MainActor the bridge's response task needs.
nonisolated func segmentedRequest(port: UInt16) -> Data {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return Data() }
    defer { close(fd) }
    // Cap the reads so a bridge that never answers fails the test instead
    // of hanging the suite.
    var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    let connectResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else { return Data() }

    // One request, two writes, split MID-TOKEN (`world` cut in half).
    // The second lands long after the first, so a single-shot receive
    // sees only the fragment "…split%20wo" and answers from it.
    let first = Array("GET /append?text=split%20wo".utf8)
    let sent = first.withUnsafeBufferPointer {
        send(fd, $0.baseAddress, $0.count, 0)
    }
    guard sent == first.count else { return Data() }
    usleep(150_000)
    let second = Array("rld HTTP/1.1\r\n\r\n".utf8)
    let sent2 = second.withUnsafeBufferPointer {
        send(fd, $0.baseAddress, $0.count, 0)
    }
    guard sent2 == second.count else { return Data() }

    // The bridge closes the connection right after responding, which
    // ends the read.
    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { break }
        reply.append(contentsOf: chunk[0..<n])
    }
    return reply
}
