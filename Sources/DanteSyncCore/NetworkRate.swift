import Foundation

/// What the menu bar shows: the leader's rate, and who disagrees with it.
/// The leader (the Pulse, clocked by the Metric Halo's MADI) is the domain's clock, so its
/// heartbeat rate is the network's rate; every other device is either at it or mismatched.
public struct NetworkRate: Equatable {
    public struct Reading: Equatable {
        public let label: String
        public let rate: Int?
        /// Nil for a CoreAudio device: it is read on the spot, so it is never stale.
        public let lastHeard: Date?

        public init(label: String, rate: Int?, lastHeard: Date? = nil) {
            self.label = label
            self.rate = rate
            self.lastHeard = lastHeard
        }
    }

    /// The leader's rate; without a fresh leader (or with none chosen), the most common fresh rate.
    public let rate: Int?
    /// Nil when the rate came from the majority.
    public let leader: String?
    public let mismatched: [Reading]
    /// Heard from once, but no heartbeat within `staleAfter`: left out of the rate and the mismatch.
    public let stale: [Reading]

    public init(readings: [Reading], leaderMatch: String?, now: Date, staleAfter: TimeInterval = 5) {
        let isFresh = { (reading: Reading) in reading.lastHeard.map { now.timeIntervalSince($0) <= staleAfter } ?? true }
        let fresh = readings.filter { isFresh($0) && $0.rate != nil }
        stale = readings.filter { !isFresh($0) }

        let found = leaderMatch.flatMap { match in fresh.first { $0.label.localizedCaseInsensitiveContains(match) } }
        // Without a leader, ties go to the higher rate, so the answer doesn't depend on reading order.
        let counts = Dictionary(fresh.compactMap(\.rate).map { ($0, 1) }, uniquingKeysWith: +)
        let domainRate = found?.rate ?? counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
        leader = found?.label
        rate = domainRate
        mismatched = fresh.filter { $0.rate != domainRate }
    }

    /// The menu bar title: "48k", "48k ⚠" when anything disagrees, "—" when nothing is heard.
    public var title: String {
        guard let rate else { return "—" }
        return formatRate(rate) + (mismatched.isEmpty ? "" : " ⚠")
    }
}
