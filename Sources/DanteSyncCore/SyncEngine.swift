import Foundation

public struct SyncOptions {
    /// The CoreAudio device whose rate the user changed. It is the target when `targetRate`
    /// is nil, and it is the one CoreAudio device not set.
    public enum Source: String {
        case metricHalo = "Metric Halo"
        case usb16x16 = "USB 16x16"
    }

    /// Rate to apply; nil means read it from `source` via CoreAudio.
    public var targetRate: Int?
    public var source = Source.metricHalo
    /// Set the Metric Halo first when it is not the source: the Pulse locks to its MADI clock,
    /// so the Pulse cannot settle at a rate the Metric Halo is not at.
    public var followMaster = true
    /// Set the USB 16x16 (the Pi's gadget) with the Dante followers.
    public var followUSB16x16 = true
    /// Case-insensitive substring identifying the clock leader (the Pulse 16 DX).
    public var leaderMatch = "PULSE"
    /// Case-insensitive substrings of device names (or IDs) that must not follow.
    public var exclude: [String] = []
    public var dryRun = false
    /// Moving up a rate band can reduce channel counts; refuse unless explicitly allowed.
    public var allowBandUp = false
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

        guard let target = options.targetRate ?? sourceRate(options.source) else {
            report.aborted = "no \(options.source.rawValue) found in CoreAudio and no --rate given"
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
            } else if leader == nil, device.label.localizedCaseInsensitiveContains(options.leaderMatch) {
                leader = device
            } else {
                followers.append(device)
            }
        }
        guard let leader else {
            report.aborted = "clock leader matching \"\(options.leaderMatch)\" not found; nothing changed"
            return report
        }

        let movingUp = ([leader] + followers).filter { SampleRate.band(target) > SampleRate.band($0.sampleRate!) }
        if !movingUp.isEmpty && !options.allowBandUp && !options.dryRun {
            report.aborted = "\(formatRate(target)) is a higher rate band than " +
                movingUp.map { "\($0.label) (\(formatRate($0.sampleRate!)))" }.joined(separator: ", ") +
                "; channel counts may drop. Re-run with --allow-band-up to proceed. Nothing changed"
            return report
        }

        let master = options.followMaster && options.source != .metricHalo
            ? CoreAudioRate.findDevice(uidPrefix: CoreAudioRate.metricHaloUIDPrefix) : nil
        let usb = options.followUSB16x16 && options.source != .usb16x16
            ? CoreAudioRate.findDevice(uidPrefix: CoreAudioRate.usb16x16UIDPrefix) : nil
        if options.followUSB16x16 && options.source != .usb16x16 && usb == nil {
            report.results.append(.init(device: "USB 16x16", outcome: .skipped, detail: "not in CoreAudio (gadget not connected)"))
        }

        if options.dryRun {
            for device in [master, usb].compactMap({ $0 }) {
                report.results.append(planCoreAudio(target, device))
            }
            for device in [leader] + followers {
                let current = device.sampleRate!
                report.results.append(current == target
                    ? .init(device: device.label, outcome: .alreadyAtRate, detail: formatRate(current))
                    : .init(device: device.label, outcome: .planned, detail: "\(formatRate(current)) → \(formatRate(target)) on port \(device.settingsPort)"
                            + (SampleRate.band(target) > SampleRate.band(current) && !options.allowBandUp ? " (needs --allow-band-up)" : "")))
            }
            return report
        }

        // 0. The clock master, when the change came from somewhere else.
        if let master {
            let result = await applyCoreAudio(target, to: master, timeout: options.rateTimeout)
            report.results.append(result)
            if result.outcome == .failed {
                report.aborted = "clock master \(master.name) did not change; nothing else touched"
                return report
            }
        }

        // 1. Leader, then wait until it reports the word clock locked at the new rate.
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

        // 2. Everyone else in parallel, the USB 16x16 with them: the Pi takes its Dante set
        // and its gadget's rate as one change.
        async let usbResult: DeviceResult? = usb == nil ? nil
            : applyCoreAudio(target, to: usb!, timeout: options.rateTimeout, settle: options.usb882Settle)
        report.results += await apply(target, to: followers, timeout: options.rateTimeout)
        if let result = await usbResult { report.results.append(result) }
        return report
    }

    private func sourceRate(_ source: SyncOptions.Source) -> Int? {
        let prefix = source == .metricHalo ? CoreAudioRate.metricHaloUIDPrefix : CoreAudioRate.usb16x16UIDPrefix
        guard let device = CoreAudioRate.findDevice(uidPrefix: prefix) else { return nil }
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
