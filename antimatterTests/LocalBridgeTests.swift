import Foundation
import Testing
@testable import antimatter

@MainActor
struct LocalBridgeTests {

    /// The loopback listener must actually accept connections inside the
    /// sandbox (needs com.apple.security.network.server) — exercises the
    /// exact path the Raycast extension uses.
    @Test func bridgeAnswersPing() async throws {
        LocalBridge.shared.start()
        defer { LocalBridge.shared.stop() }

        let url = URL(string: "http://127.0.0.1:41367/ping")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("close", forHTTPHeaderField: "Connection")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Issue.record("ping request failed: \(error)")
            LocalBridge.shared.stop()
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let raw = String(decoding: data, as: UTF8.self)
        if status != 200 {
            Issue.record("unexpected status \(status): \(raw)")
            return
        }
        if let body = try? JSONDecoder().decode(ActionOutcome.self, from: data), body.ok == true {
            return
        }
        Issue.record("response did not decode to ok=true: \(raw)")
    }
}