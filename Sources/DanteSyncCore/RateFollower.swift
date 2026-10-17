import Foundation

/// Decides when a CoreAudio rate change is the user's, and so should be followed by every
/// other device. Fed a reading of every source (the Metric Halo, the USB 16x16) a few times
/// a second; pure, so it is tested without CoreAudio.
///
/// - A change must hold for `settle` seconds before it is followed (a DAW opening a session
///   can step through rates).
/// - Whichever source changed last wins: a session on the USB 16x16 at 44.1k is followed even
///   though the Metric Halo is at 48k, and the other way round.
/// - While a sync runs, and for `cooldown` seconds after it, changes are not followed but
///   reported. That stops the sync's own sets echoing back as new changes, and a device that
///   could not follow (and snapped back) from starting a tug-of-war.
/// - A source that appears (a device plugged in) is not a change; its rate is just recorded.
public struct RateFollower {
    public struct Decision: Equatable {
        public let source: String
        public let rate: Int
    }

    public enum Event: Equatable {
        case follow(Decision)
        case ignored(source: String, rate: Int, reason: String)
    }

    public let settle: TimeInterval
    public let cooldown: TimeInterval
    public private(set) var busy = false
    private var baseline: [String: Int]
    private var candidate: (source: String, rate: Int, since: Date)?
    private var quietUntil = Date.distantPast

    public init(initial: [String: Int], settle: TimeInterval = 2, cooldown: TimeInterval = 5) {
        baseline = initial
        self.settle = settle
        self.cooldown = cooldown
    }

    /// One reading of every source that is present. Returns what to do, if anything.
    public mutating func observe(_ readings: [String: Int], at now: Date) -> [Event] {
        var events: [Event] = []
        for source in readings.keys.sorted() {
            let rate = readings[source]!
            guard let before = baseline[source] else {
                baseline[source] = rate
                continue
            }
            guard before != rate else { continue }
            baseline[source] = rate
            if busy {
                events.append(.ignored(source: source, rate: rate, reason: "a sync is running"))
            } else if now < quietUntil {
                events.append(.ignored(source: source, rate: rate, reason: "within \(Int(cooldown)) s of the last sync"))
            } else {
                candidate = (source, rate, now)
            }
        }
        for source in baseline.keys where readings[source] == nil {
            baseline[source] = nil
        }
        if let pending = candidate, !busy, now.timeIntervalSince(pending.since) >= settle {
            candidate = nil
            if readings[pending.source] == pending.rate {
                busy = true
                events.append(.follow(Decision(source: pending.source, rate: pending.rate)))
            }
        }
        return events
    }

    /// The sync for the last decision is over. The readings as they now stand are the new
    /// baseline, so a device left at another rate is not mistaken for a change.
    public mutating func finished(_ readings: [String: Int], at now: Date) {
        busy = false
        candidate = nil
        baseline = readings
        quietUntil = now.addingTimeInterval(cooldown)
    }
}
