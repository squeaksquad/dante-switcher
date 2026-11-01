import Foundation

/// The follow loop that `dante-sync watch` and the app run: polls every rate source four times
/// a second and syncs everything else to a change that holds for 2 s, the changed device being
/// the source (`RateFollower` decides). Runs until its task is cancelled.
public final class RateWatcher {
    private let network: DanteNetwork
    private let options: SyncOptions
    private let log: (String) -> Void
    private let report: (SyncReport) -> Void

    public init(network: DanteNetwork, options: SyncOptions, log: @escaping (String) -> Void,
                report: @escaping (SyncReport) -> Void) {
        self.network = network
        self.options = options
        self.log = log
        self.report = report
    }

    /// Each present source's rate, by `uidMatch`. Polling rather than a listener, so a device
    /// that re-enumerates is found again without re-binding.
    public static func readings(_ sources: [RateSource]) -> [String: Int] {
        var now: [String: Int] = [:]
        for source in sources {
            if let device = source.find(), let rate = CoreAudioRate.nominalRate(of: device) {
                now[source.uidMatch] = rate
            }
        }
        return now
    }

    public func run() async {
        let start = Self.readings(options.sources)
        func name(_ match: String) -> String { options.sources.first { $0.uidMatch == match }?.name ?? match }
        log("Watching " + (start.isEmpty ? "(none of \(options.sources.map(\.name).joined(separator: ", ")) yet)"
            : start.sorted { name($0.key) < name($1.key) }.map { "\(name($0.key)) \(formatRate($0.value))" }.joined(separator: ", "))
            + (options.dryRun ? " — dry run, nothing is set" : ""))
        if Set(start.values).count > 1 {
            log("They disagree now; nothing is done until one of them changes.")
        }
        var follower = RateFollower(initial: start)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { break }
            for event in follower.observe(Self.readings(options.sources), at: Date()) {
                switch event {
                case .ignored(let source, let rate, let reason):
                    log("\(name(source)) → \(formatRate(rate)) not followed: \(reason)")
                case .follow(let decision):
                    log("")
                    log("\(name(decision.source)) changed to \(formatRate(decision.rate)); syncing everything else")
                    if let device = CoreAudioRate.findDevice(uidPrefix: decision.source),
                       CoreAudioRate.settleTime(decision.rate, uid: device.uid, usb882Settle: options.usb882Settle) > 0 {
                        // The app that set it has likely started audio already, so no hold here can help.
                        log("WARNING: an app set the USB-AoIP to 88.2k. If it started audio within a few seconds,"
                            + " macOS may pass only silence on the USB-AoIP, both ways, until the rate is changed again."
                            + " If so: stop audio on it, set it to 48k, wait 10 s, set 88.2k, wait 10 s, then start audio.")
                    }
                    var run = options
                    run.targetRate = decision.rate
                    run.followsSource = true
                    run.source = decision.source
                    // In a task of its own so that cancelling the watcher lets a sync finish: SyncEngine
                    // waits with `try? Task.sleep`, which would return at once and spin until each deadline.
                    let engine = SyncEngine(network: network, log: log)
                    report(await Task { await engine.run(run) }.value)
                    follower.finished(Self.readings(options.sources), at: Date())
                }
            }
        }
    }
}
