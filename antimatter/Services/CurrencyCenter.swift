import Combine
import Foundation

/// Live currency and cryptocurrency conversions, opt-in.
///
/// Rates come from a single free source (Coinbase's exchange-rates endpoint),
/// which prices both fiat and crypto in terms of a USD base. The table is
/// fetched only when the user switches on `conversion.network` (or on launch
/// if they already did), cached to disk, and refreshed at most once an hour —
/// so a committed line reads a *synchronous* cached table and never blocks on
/// the network. With the switch off, or before a successful fetch, no pair
/// converts and a currency-shaped line simply stays text.
///
/// `rates[symbol]` is the amount of `symbol` you get for 1 USD, so
/// `value to = value from * rates[to] / rates[from]`.
///
/// The table lives in a thread-safe box so the synchronous commit path
/// (`UnitConverter`) and non-`@MainActor` unit tests can read it without
/// hopping to an actor. The class itself is not actor-isolated; only the
/// published `lastError` is touched on the main actor.
final class CurrencyCenter: ObservableObject {
    static let shared = CurrencyCenter()

    /// When the cache was fetched; used to throttle refreshes to an hour.
    private(set) var lastFetched: Date?
    @Published private(set) var lastError: String?

    private let fileURL: URL
    private let now: () -> Date
    private var isFetching = false

    init(fileURL: URL = CurrencyCenter.defaultFileURL(), now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        load()
    }

    nonisolated static func defaultFileURL() -> URL {
        StorageLocation.directory(named: "currency").appendingPathComponent("rates.json")
    }

    // MARK: Synchronous cache reads (commit path)

    /// Thread-safe read of one symbol's USD rate, or nil.
    nonisolated static func cachedRate(_ symbol: String) -> Double? {
        RateCache.shared.rate(for: symbol)
    }

    /// Synchronous conversion used by UnitConverter's commit path.
    nonisolated static func convert(value: Double, from: String, to: String) -> Double? {
        let fromSymbol = from.uppercased()
        let toSymbol = to.uppercased()
        guard let fromRate = RateCache.shared.rate(for: fromSymbol),
              let toRate = RateCache.shared.rate(for: toSymbol)
        else { return nil }
        return value * toRate / fromRate
    }

    /// True when `symbol` is a code we currently have a rate for.
    nonisolated static func isConvertible(_ symbol: String) -> Bool {
        RateCache.shared.rate(for: symbol) != nil
    }

    /// The cached table snapshot (for the Settings UI).
    nonisolated static var cachedSymbols: [String] {
        RateCache.shared.symbols
    }

    // MARK: Instance lifecycle

    /// Call on launch and when the toggle flips: loads the cache and, when
    /// networking is enabled, refreshes from the network if the cache is stale.
    @MainActor
    func activate() {
        if CurrencyPreference.networkEnabled {
            refreshIfStale()
        }
    }

    /// Fetches fresh rates iff networking is enabled and the cache is older
    /// than an hour (or empty). Returns without doing anything otherwise.
    @MainActor
    func refreshIfStale() {
        guard CurrencyPreference.networkEnabled else { return }
        if let lastFetched, now().timeIntervalSince(lastFetched) < 60 * 60 { return }
        refreshNow()
    }

    /// Forces a network refresh now (the Settings toggle / `.currency refresh`).
    @MainActor
    func refreshNow() {
        guard CurrencyPreference.networkEnabled, !isFetching else { return }
        isFetching = true
        Task { @MainActor [weak self] in
            defer { self?.isFetching = false }
            guard let self else { return }
            do {
                let data = try await URLSession.shared.data(from: RatesEndpoint.url).0
                let decoded = try JSONDecoder().decode(RatesResponse.self, from: data)
                let table = decoded.data.rates.compactMapValues { Double($0) }
                guard !table.isEmpty else {
                    lastError = "No rates returned."
                    return
                }
                RateCache.shared.replace(with: table)
                lastFetched = now()
                lastError = nil
                persist()
                DebugLog.log("currency rates refreshed — \(table.count) symbols")
            } catch {
                lastError = error.localizedDescription
                DebugLog.log("currency refresh failed — \(error.localizedDescription)")
            }
        }
    }

    // MARK: Persistence

    private struct CachedRates: Codable {
        var rates: [String: Double]
        var fetchedAt: Date
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder().decode(CachedRates.self, from: data)
        else { return }
        RateCache.shared.replace(with: cached.rates)
        lastFetched = cached.fetchedAt
    }

    private func persist() {
        let snapshot = RateCache.shared.snapshot()
        guard let data = try? JSONEncoder().encode(CachedRates(rates: snapshot, fetchedAt: lastFetched ?? now())) else { return }
        Persistence.writeData(data, to: fileURL)
    }
}

/// Decodable mirror of `https://api.coinbase.com/v2/exchange-rates?currency=USD`.
private struct RatesResponse: Codable {
    struct Data: Codable { var rates: [String: String] }
    var data: Data
}

private enum RatesEndpoint {
    static let url = URL(string: "https://api.coinbase.com/v2/exchange-rates?currency=USD")!
}