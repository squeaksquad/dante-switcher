import DanteSyncCore
import Foundation
import Observation

/// Listens to the Dante heartbeats and reads the chosen CoreAudio rate sources once a second.
/// Sets rates only when following is on (`RateWatcher`, as `dante-sync watch`) or on "Sync Now".
@MainActor @Observable
final class RateMonitor {
    struct Row: Identifiable {
        let id: String
        let label: String
        let rate: String
        let mark: String
        let isCoreAudio: Bool
    }

    static let interfaceKey = "interface"
    static let followKey = "follow"
    static let sourcesKey = "sources"
    static let leaderIDKey = "leaderID"
    static let leaderNameKey = "leaderName"

    /// The CoreAudio devices that move the network. None until chosen: nothing is assumed
    /// about which interface someone has.
    private(set) var sources: [RateSource] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(sources), forKey: Self.sourcesKey)
            restartWatcher()
        }
    }
    /// The Dante clock leader, by device ID; nil for none. The name is kept to show it while it is not heard.
    private(set) var leaderID: String?
    private(set) var leaderName: String?
    /// Every CoreAudio device that offers a Dante rate, for the source menu.
    private(set) var audioDevices: [CoreAudioRate.Device] = []
    /// The Dante devices heard, for the leader menu.
    private(set) var danteDevices: [DanteNetwork.Device] = []

    /// Off until turned on: following moves every device on the network.
    var follow: Bool {
        didSet {
            UserDefaults.standard.set(follow, forKey: Self.followKey)
            restartWatcher()
        }
    }
    private(set) var syncing = false
    private(set) var lastReport: SyncReport?
    private(set) var lastReportAt: Date?
    /// The sync log, newest last, capped.
    private(set) var log: [String] = []

    private(set) var networkRate = NetworkRate(readings: [], leaderMatch: nil, now: Date())
    private(set) var rows: [Row] = []
    /// Set when the network isn't open, in place of the rows.
    private(set) var problem: String?
    private(set) var interfaces: [NetworkInterface] = []
    var interfaceName: String {
        didSet {
            UserDefaults.standard.set(interfaceName, forKey: Self.interfaceKey)
            close()
            refresh()
        }
    }

    private var network: DanteNetwork?
    private var watcher: Task<Void, Never>?
    private var syncNowRunning = false
    private var timer: Timer?

    init() {
        interfaceName = UserDefaults.standard.string(forKey: Self.interfaceKey) ?? "en7"
        follow = UserDefaults.standard.bool(forKey: Self.followKey)
        sources = UserDefaults.standard.data(forKey: Self.sourcesKey).flatMap { try? JSONDecoder().decode([RateSource].self, from: $0) } ?? []
        leaderID = UserDefaults.standard.string(forKey: Self.leaderIDKey)
        leaderName = UserDefaults.standard.string(forKey: Self.leaderNameKey)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var title: String { problem == nil ? networkRate.title : "—" }

    func refresh() {
        interfaces = NetworkInterface.all()
        audioDevices = CoreAudioRate.devices()
        // The sockets are bound to the interface's address, so a new address (sleep/wake, a cable
        // pulled, DHCP giving up to 169.254) needs a fresh DanteNetwork, not a fallback to another interface.
        guard let interface = NetworkInterface.lookup(interfaceName) else {
            close()
            show(problem: "\(interfaceName) has no IPv4 address")
            return
        }
        if network?.interface.ipv4 != interface.ipv4 {
            close()
            do {
                let opened = try DanteNetwork(interfaceName: interfaceName)
                opened.start()
                network = opened
                restartWatcher()
            } catch {
                show(problem: "Can't listen on \(interfaceName): \(error)")
                return
            }
        }
        guard let network else { return }
        problem = nil

        let now = Date()
        var labels: [String: String] = [:]
        var readings: [NetworkRate.Reading] = []
        danteDevices = network.snapshot()
        let leaderLabel = danteDevices.first { $0.id == leaderID }?.label
        if let leaderLabel, leaderLabel != leaderName {
            leaderName = leaderLabel
            UserDefaults.standard.set(leaderLabel, forKey: Self.leaderNameKey)
        }
        for device in danteDevices {
            // A device seen only through mDNS has no rate yet; leave it out of the reading.
            readings.append(NetworkRate.Reading(label: device.label, rate: device.lastHeartbeat == nil ? nil : device.sampleRate,
                                                lastHeard: device.lastHeartbeat))
            labels[device.label] = device.isDVS ? "\(device.label) (DVS)" : device.label
        }
        // Labels are the readings' identity, and a Dante device can share a CoreAudio device's name
        // (the Pi's Dante side and its gadget are both USB-AoIP), so these carry a suffix.
        // The menu shows them under a CoreAudio heading, so it drops the suffix.
        var coreAudio: Set<String> = []
        for source in sources {
            guard let device = source.find() else { continue }
            let label = "\(source.name) (CoreAudio)"
            readings.append(NetworkRate.Reading(label: label, rate: CoreAudioRate.nominalRate(of: device)))
            labels[label] = source.name + (source.clocksNetwork ? "   clocks the network" : "")
            coreAudio.insert(label)
        }
        networkRate = NetworkRate(readings: readings, leaderMatch: leaderLabel, now: now)

        let mismatched = Set(networkRate.mismatched.map(\.label))
        let stale = Set(networkRate.stale.map(\.label))
        rows = readings.map { reading in
            let mark = reading.label == networkRate.leader ? "leader"
                : stale.contains(reading.label) ? "no heartbeat"
                : mismatched.contains(reading.label) ? "⚠" : ""
            return Row(id: reading.label, label: labels[reading.label] ?? reading.label,
                       rate: reading.rate.map(formatRate) ?? "—", mark: mark, isCoreAudio: coreAudio.contains(reading.label))
        }
    }

    private func show(problem: String) {
        self.problem = problem
        networkRate = NetworkRate(readings: [], leaderMatch: nil, now: Date())
        rows = []
    }

    func isSource(_ device: CoreAudioRate.Device) -> Bool {
        sources.contains { CoreAudioRate.uid(device.uid, matches: $0.uidMatch) }
    }

    func toggleSource(_ device: CoreAudioRate.Device) {
        if isSource(device) {
            sources.removeAll { CoreAudioRate.uid(device.uid, matches: $0.uidMatch) }
        } else {
            sources.append(RateSource(name: device.name, uidMatch: CoreAudioRate.stableMatch(for: device.uid), clocksNetwork: false))
        }
    }

    func removeSource(_ source: RateSource) {
        sources.removeAll { $0 == source }
    }

    func setClocksNetwork(_ source: RateSource, _ on: Bool) {
        guard let index = sources.firstIndex(of: source) else { return }
        sources[index].clocksNetwork = on
    }

    func setLeader(_ device: DanteNetwork.Device?) {
        leaderID = device?.id
        leaderName = device?.label
        UserDefaults.standard.set(leaderID, forKey: Self.leaderIDKey)
        UserDefaults.standard.set(leaderName, forKey: Self.leaderNameKey)
        restartWatcher()
    }

    private func options() -> SyncOptions {
        var options = SyncOptions()
        options.sources = sources
        options.leaderMatch = leaderID
        return options
    }

    /// Syncs everything to `source`'s rate, as `dante-sync sync --source` does. The watcher is
    /// stopped meanwhile, or it would take this sync's own sets for a change to follow.
    func syncNow(to source: RateSource) {
        guard let network, !syncing else { return }
        watcher?.cancel()
        watcher = nil
        syncing = true
        syncNowRunning = true
        append("Sync Now: everything to \(source.name)'s rate")
        var run = options()
        run.source = source.uidMatch
        Task {
            let engine = SyncEngine(network: network) { [weak self] line in Task { @MainActor in self?.append(line) } }
            finish(await engine.run(run))
            syncNowRunning = false
            restartWatcher()
        }
    }

    private func restartWatcher() {
        watcher?.cancel()
        watcher = nil
        guard follow, let network, !syncNowRunning, !sources.isEmpty else { return }
        let rateWatcher = RateWatcher(network: network, options: options(),
                                      log: { [weak self] line in Task { @MainActor in self?.append(line) } },
                                      report: { [weak self] report in Task { @MainActor in self?.finish(report) } })
        watcher = Task { await rateWatcher.run() }
    }

    private func finish(_ report: SyncReport) {
        syncing = false
        lastReport = report
        lastReportAt = Date()
        for result in report.results {
            append("  \(result.device): \(result.outcome.rawValue), \(result.detail)")
        }
        append(report.summary)
    }

    private func append(_ line: String) {
        guard !line.isEmpty else { return }
        // A follow starts with this line (RateWatcher); mark the sync as running until its report.
        if line.hasSuffix("syncing everything else") { syncing = true }
        log.append(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium) + "  " + line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func close() {
        watcher?.cancel()
        watcher = nil
        network?.stop()
        network = nil
    }
}
