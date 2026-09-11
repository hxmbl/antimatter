import Foundation
import Testing
@testable import antimatter

@MainActor
@Suite(.serialized)
struct LocalBridgeTests {

    /// Exercise the request path used by the extension, not just listener
    /// liveness: the bridge must decode a query, run the action, and return
    /// the resulting outcome as JSON.
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

    private func resetActiveNote() {
        var note = NoteStore.shared.activeNote
        note.text = ""
        NoteStore.shared.activeNote = note
        NoteStore.shared.flush()
    }
}
