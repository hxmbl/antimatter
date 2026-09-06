import Foundation

// With the app's default-MainActor isolation, these helpers must be
// explicitly nonisolated so the synchronous conversion commit path can read
// them from anywhere (and non-@MainActor unit tests can exercise them).

/// UserDefaults key: opt-in switch that lets currency conversion reach the
/// network. Off by default — a bare number→unit conversion stays fully
/// offline, and the note can never phone home until the user says so.
enum CurrencyPreference {
    nonisolated static let networkKey = "conversion.network"

    nonisolated static var networkEnabled: Bool {
        UserDefaults.standard.object(forKey: networkKey) as? Bool ?? false
    }
}

/// Thread-safe bag holding the last good rate table. The fetching
/// `CurrencyCenter` instance writes to it; `nonisolated` readers (the
/// synchronous commit path in `UnitConverter`, and non-`@MainActor` unit
/// tests) read it through a lock. Explicitly Sendable: every access is
/// guarded by `lock`, which is exactly what `@unchecked` asserts.
final class RateCache: @unchecked Sendable {
    nonisolated static let shared = RateCache()

    // unsafe is warranted: `rates` is only ever touched under `lock` below.
    nonisolated(unsafe) private var rates: [String: Double] = [:]
    nonisolated private let lock = NSLock()

    nonisolated func snapshot() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return rates
    }

    nonisolated func rate(for symbol: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return rates[symbol.uppercased()]
    }

    nonisolated func replace(with new: [String: Double]) {
        lock.lock()
        defer { lock.unlock() }
        rates = new
    }

    nonisolated var symbols: [String] {
        lock.lock()
        defer { lock.unlock() }
        return rates.keys.sorted()
    }
}