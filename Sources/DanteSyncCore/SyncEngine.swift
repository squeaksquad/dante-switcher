import Foundation

public struct SyncOptions {
    /// Rate to apply; nil means read it from the leading source via CoreAudio.
    public var targetRate: Int?
    /// The CoreAudio devices that move the network; every one but the leading source is set.
    public var sources: [RateSource] = [.metricHalo, .usbAoIP]
    /// `uidMatch` of the source whose rate the user changed; nil means the first source.
    public var source: String?
    /// The clock leader (the Pulse 16 DX): a device ID (EUI-64), or a case-insensitive
    /// substring of its name. It is set first and waited on for word-clock lock. Nil: no
    /// leader, every Dante device is set together.
    public var leaderMatch: String? = "PULSE"
    /// Case-insensitive substrings of device names (or IDs) that must not follow.
    public var exclude: [String] = []
    public var dryRun = false
    /// Moving up a rate band can reduce channel counts; an explicit `--rate` that does is
    /// refused unless this is set. A follow (`followsSource`) never needs it.
    public var allowBandUp = false
    /// The target is the rate the user already set on `source` (`sync --source`, or `watch`
    /// passing on the rate it saw): the rest of the domain has to follow it, band or not.
    /// True whenever `targetRate` is nil.
    public var followsSource = false
    public var discoveryWait: TimeInterval = 4
    /// After the USB 16x16 is verified at 88.2k, hold this long before the sync reports.
    /// macOS (AppleUSBAudio) latches the device's audio into zeros, both ways, when an app
    /// starts audio within a few seconds of an 88.2k stream restart; the USB stream itself
    /// stays correct. Measured on the Pi's multi-rate gadget (USB 16x16 repo,
    /// PROJECT_HANDOFF.md, 2026-10-18): bad 7 of 7 with audio ~2.5 s after the set, clean
    /// every time from ~7 s. 44.1k, 48k and 96k are not affected.
    public var usb882Settle: TimeInterval = 10
    public var rateTimeout: TimeInterval = 20
    public var lockTimeout: TimeInterval = 15

    public init() {}

    public var leadingSource: RateSource? {
        sources.first { $0.uidMatch == source } ?? sources.first
    }

    public func isLeader(_ device: DanteNetwork.Device) -> Bool {
        guard let leaderMatch else { return false }
        return device.id == leaderMatch.lowercased() || device.label.localizedCaseInsensitiveContains(leaderMatch)
    }
}

public struct DeviceResult {
    public enum Outcome: String {
        case changed, alreadyAtRate = "already at rate", planned = "would change", skipped, failed
    }

    public let device: String
    public let outcome: Outcome
    public let detail: String
}

public struct SyncReport {
    public var targetRate: Int?
    public var results: [DeviceResult] = []
    public var aborted: String?

    public var summary: String {
        if let aborted { return "Sync aborted: \(aborted)" }
        let counts = Dictionary(grouping: results, by: \.outcome).mapValues(\.count)
        let parts = [DeviceResult.Outcome.changed, .alreadyAtRate, .planned, .skipped, .failed]
            .compactMap { outcome in counts[outcome].map { "\($0) \(outcome.rawValue)" } }
        return "\(targetRate.map(formatRate) ?? "?"): " + parts.joined(separator: ", ")
    }
}

/// The band-up rule: a move to a higher rate band can drop channel counts (at 96k the Pulse has
/// 32 Dante channels each way, not 64). An explicit rate needs `allowBandUp`; a follow of the
/// source goes ahead with a note.
public struct BandUpCheck: Equatable {
    /// Set when the sync must not run.
    public let abort: String?
    /// Set when the sync runs across a band: log it.
    public let note: String?
    /// Devices this run would move up a band without consent (shown in a dry run's plan).
    public let needsConsent: Bool

    public init(target: Int, devices: [(label: String, rate: Int)], options: SyncOptions) {
        let movingUp = devices.filter { SampleRate.band(target) > SampleRate.band($0.rate) }
        let names = movingUp.map { "\($0.label) (\(formatRate($0.rate)))" }.joined(separator: ", ")
        let follows = options.followsSource || options.targetRate == nil
        needsConsent = !movingUp.isEmpty && !follows && !options.allowBandUp
        if movingUp.isEmpty {
            abort = nil
            note = nil
        } else if needsConsent && !options.dryRun {
            abort = "\(formatRate(target)) is a higher rate band than \(names); channel counts may drop."
                + " Re-run with --allow-band-up to proceed. Nothing changed"
            note = nil
        } else {
            abort = nil
            note = "NOTE: \(formatRate(target)) is a higher rate band than \(names); channel counts may drop"
                + (follows ? " (following \(options.leadingSource?.name ?? "the source"))" : "")
        }
    }
}

public func formatRate(_ rate: Int) -> String {
    let khz = Double(rate) / 1000
    return khz == khz.rounded() ? "\(Int(khz))k" : String(format: "%.1fk", khz)
}

/// One sync pass: leader first, wait for it to lock to MADI, then everyone else.
public final class SyncEngine {
    private let network: DanteNetwork
    private let log: (String) -> Void

    public init(network: DanteNetwork, log: @escaping (String) -> Void) {
        self.network = network
        self.log = log
    }

    public func run(_ options: SyncOptions) async -> SyncReport {
        var report = SyncReport()

        guard let target = options.targetRate ?? options.leadingSource.flatMap(sourceRate) else {
            report.aborted = options.leadingSource.map { "no \($0.name) found in CoreAudio and no --rate given" }
                ?? "no rate source chosen and no --rate given"
            return report
        }
        guard SampleRate.all.contains(target) else {
            report.aborted = "\(target) Hz is not a Dante sample rate"
            return report
        }
        report.targetRate = target
        log("Target rate \(formatRate(target)). Listening for devices for \(Int(options.discoveryWait)) s…")
        try? await Task.sleep(nanoseconds: UInt64(options.discoveryWait * 1e9))

        var followers: [DanteNetwork.Device] = []
        var leader: DanteNetwork.Device?
        for device in network.snapshot() {
            if options.exclude.contains(where: { device.label.localizedCaseInsensitiveContains($0) || device.id.contains($0.lowercased()) }) {
                report.results.append(.init(device: device.label, outcome: .skipped, detail: "excluded"))
            } else if device.ip == nil || device.sampleRate == nil {
                report.results.append(.init(device: device.label, outcome: .skipped, detail: "no heartbeat with a sample rate; can't set or verify"))
            } else if leader == nil, options.isLeader(device) {
                leader = device
            } else {
                followers.append(device)
            }
        }
        if let match = options.leaderMatch, leader == nil {
            report.aborted = "clock leader \"\(match)\" not found; nothing changed"
            return report
        }
        let dante = (leader.map { [$0] } ?? []) + followers

        let bandUp = BandUpCheck(target: target, devices: dante.map { ($0.label, $0.sampleRate!) }, options: options)
        if let abort = bandUp.abort {
            report.aborted = abort
            return report
        }
        if let note = bandUp.note { log(note) }

        // Every source but the leading one is set: the ones that clock the network first.
        var clocking: [CoreAudioRate.Device] = []
        var alongside: [CoreAudioRate.Device] = []
        for source in options.sources where source.uidMatch != options.leadingSource?.uidMatch {
            guard let device = source.find() else {
                report.results.append(.init(device: source.name, outcome: .skipped, detail: "not in CoreAudio"))
                continue
            }
            if source.clocksNetwork { clocking.append(device) } else { alongside.append(device) }
        }

        if options.dryRun {
            for device in clocking + alongside {
                report.results.append(planCoreAudio(target, device))
            }
            for device in dante {
                let current = device.sampleRate!
                report.results.append(current == target
                    ? .init(device: device.label, outcome: .alreadyAtRate, detail: formatRate(current))
                    : .init(device: device.label, outcome: .planned, detail: "\(formatRate(current)) → \(formatRate(target)) on port \(device.settingsPort)"
                            + (SampleRate.band(target) > SampleRate.band(current) && bandUp.needsConsent ? " (needs --allow-band-up)" : "")))
            }
            return report
        }

        // 0. The sources that clock the network, when the change came from somewhere else.
        for device in clocking {
            let result = await applyCoreAudio(target, to: device, timeout: options.rateTimeout)
            report.results.append(result)
            if result.outcome == .failed {
                report.aborted = "\(device.name) clocks the network and did not change; nothing else touched"
                return report
            }
        }

        // 1. Leader, then wait until it reports the word clock locked at the new rate.
        if let leader {
            let leaderResult = await apply(target, to: [leader], timeout: options.rateTimeout)
            report.results += leaderResult
            if leaderResult.first?.outcome == .failed {
                report.aborted = "leader \(leader.label) did not change; followers left alone"
                return report
            }
            if await waitForLock(leader, timeout: options.lockTimeout) {
                log("\(leader.label) word clock locked.")
            } else {
                log("WARNING: \(leader.label) did not report word clock lock within \(Int(options.lockTimeout)) s; continuing.")
            }
        }

        // 2. Everyone else in parallel, the other sources with them: the USB-AoIP's Pi takes its
        // Dante set and its gadget's rate as one change.
        let settle = options.usb882Settle
        let others = alongside
        async let sourceResults: [DeviceResult] = withTaskGroup(of: DeviceResult.self) { group in
            for device in others {
                group.addTask { await self.applyCoreAudio(target, to: device, timeout: options.rateTimeout, settle: settle) }
            }
            var results: [DeviceResult] = []
            for await result in group { results.append(result) }
            return results
        }
        report.results += await apply(target, to: followers, timeout: options.rateTimeout)
        report.results += await sourceResults
        return report
    }

    private func sourceRate(_ source: RateSource) -> Int? {
        guard let device = source.find() else { return nil }
        let rate = CoreAudioRate.nominalRate(of: device)
        log("\(device.name): \(rate.map(formatRate) ?? "unknown")")
        return rate
    }

    private func planCoreAudio(_ target: Int, _ device: CoreAudioRate.Device) -> DeviceResult {
        let current = CoreAudioRate.nominalRate(of: device)
        if current == target {
            return .init(device: device.name, outcome: .alreadyAtRate, detail: formatRate(target))
        }
        let offered = CoreAudioRate.availableRates(of: device)
        let from = current.map(formatRate) ?? "?"
        return offered.contains(target)
            ? .init(device: device.name, outcome: .planned, detail: "\(from) → \(formatRate(target)) via CoreAudio")
            : .init(device: device.name, outcome: .planned, detail: "\(from) → \(formatRate(target)) via CoreAudio, but it offers only "
                    + offered.map(formatRate).joined(separator: ", ") + " (would fail)")
    }

    /// Sets a CoreAudio device and waits until it reads the new rate, then holds for the
    /// device's settle time at that rate, if it has one (`CoreAudioRate.settleTime`).
    private func applyCoreAudio(_ target: Int, to device: CoreAudioRate.Device, timeout: TimeInterval,
                                settle: TimeInterval = 0) async -> DeviceResult {
        let current = CoreAudioRate.nominalRate(of: device)
        if current == target {
            return .init(device: device.name, outcome: .alreadyAtRate, detail: formatRate(target))
        }
        let sentAt = Date()
        do {
            try CoreAudioRate.setNominalRate(target, on: device)
        } catch {
            return .init(device: device.name, outcome: .failed, detail: "\(error)")
        }
        log("Set \(device.name) \(current.map(formatRate) ?? "?") → \(formatRate(target)) (CoreAudio)")
        if await CoreAudioRate.waitForRate(target, uid: device.uid, timeout: timeout) {
            let seconds = String(format: "%.1f", Date().timeIntervalSince(sentAt))
            let hold = CoreAudioRate.settleTime(target, uid: device.uid, usb882Settle: settle)
            guard hold > 0 else {
                return .init(device: device.name, outcome: .changed, detail: "verified by CoreAudio after \(seconds) s")
            }
            log("\(device.name) at \(formatRate(target)): holding \(Int(hold)) s before reporting; start audio on it only after this sync finishes")
            try? await Task.sleep(nanoseconds: UInt64(hold * 1e9))
            return .init(device: device.name, outcome: .changed,
                         detail: "verified by CoreAudio after \(seconds) s, then held \(Int(hold)) s (88.2k settle)")
        }
        return .init(device: device.name, outcome: .failed, detail: "still not \(formatRate(target)) after \(Int(timeout)) s")
    }

    /// Sends the set packet to every device that needs it, then waits for each heartbeat to show the new rate.
    private func apply(_ target: Int, to devices: [DanteNetwork.Device], timeout: TimeInterval) async -> [DeviceResult] {
        var results: [String: DeviceResult] = [:]
        var pending: [DanteNetwork.Device] = []
        let sentAt = Date()
        for device in devices {
            if device.sampleRate == target {
                results[device.id] = .init(device: device.label, outcome: .alreadyAtRate, detail: formatRate(target))
                continue
            }
            do {
                try network.setSampleRate(target, on: device)
                log("Set \(device.label) \(formatRate(device.sampleRate!)) → \(formatRate(target))")
                pending.append(device)
            } catch {
                results[device.id] = .init(device: device.label, outcome: .failed, detail: "send failed: \(error)")
            }
        }

        let deadline = sentAt.addingTimeInterval(timeout)
        while !pending.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            pending.removeAll { device in
                guard let now = network.device(id: device.id), let beat = now.lastHeartbeat,
                      beat > sentAt, now.sampleRate == target else { return false }
                let seconds = String(format: "%.1f", beat.timeIntervalSince(sentAt))
                results[device.id] = .init(device: device.label, outcome: .changed, detail: "verified by heartbeat after \(seconds) s")
                return true
            }
        }
        for device in pending {
            let seen = network.device(id: device.id)?.sampleRate.map(formatRate) ?? "?"
            results[device.id] = .init(device: device.label, outcome: .failed,
                                       detail: "still \(seen) after \(Int(timeout)) s (Device Lock, unsupported rate, or offline)")
        }
        return devices.compactMap { results[$0.id] }
    }

    private func waitForLock(_ leader: DanteNetwork.Device, timeout: TimeInterval) async -> Bool {
        guard let refreshed = network.device(id: leader.id), let ip = refreshed.ip else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let askedAt = Date()
            try? network.requestClockStatus(of: refreshed)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let reading = network.clockReading(ip: ip), reading.received > askedAt, reading.status.wordClockValid {
                return true
            }
        }
        return false
    }
}
