import Foundation
import Testing
@testable import antimatter

@MainActor
@Suite(.serialized)
struct LocalBridgeTests {

    /// Exercises the request path: decode query, run action, return outcome as JSON.
    @Test func bridgeExecutesAppendAndReturnsOutcome() async throws {
        resetActiveNote()
        LocalBridge.shared.start()
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

    /// A browser fetch always sends an Origin header; such requests must be
    /// refused so a cross-origin page cannot drive the loopback bridge.
    @Test func bridgeRefusesCrossOriginRequests() async throws {
        LocalBridge.shared.start()
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

    /// Same-origin-style requests (Origin: null, or none at all) still work.
    @Test func bridgeAllowsNullOrigin() async throws {
        LocalBridge.shared.start()
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

    private func resetActiveNote() {
        var note = NoteStore.shared.activeNote
        note.text = ""
        NoteStore.shared.activeNote = note
        NoteStore.shared.flush()
    }
}
