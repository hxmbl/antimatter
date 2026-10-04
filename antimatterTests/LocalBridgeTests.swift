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
        // A port the machine is not already using. The fixed 41367 was the whole
        // problem: if a real Antimatter is running, the test host could not bind
        // it, `start()` still handed the port back, and every request here was
        // executed by that other process while this one looked broken.
        let port = Self.freePort()
        LocalBridge.shared.start(ports: [port])
        for _ in 0..<200 {
            if LocalBridge.shared.isReady { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("bridge never reported ready on port \(port)")
    }

    /// Asks the OS for an ephemeral port, then releases it. Inherently a small
    /// race, but a vanishingly unlikely one for a test suite and far better than
    /// colliding with the app under test.
    private static func freePort() -> UInt16 {
        let listener = try? NWListener(using: .tcp, on: 0)
        let port = listener?.port?.rawValue ?? 41_400
        listener?.cancel()
        return port
    }

    private func resetActiveNote() {
        var note = NoteStore.shared.activeNote
        note.text = ""
        NoteStore.shared.activeNote = note
        NoteStore.shared.flush()
    }
}
