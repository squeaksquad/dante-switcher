import DanteSyncCore
import Foundation
import Observation

/// Read-only: listens to the Dante heartbeats and reads the two CoreAudio devices once a
/// second. It sends nothing on the network and sets no rate.
@MainActor @Observable
final class RateMonitor {
    struct Row: Identifiable {
        let id: String
        let label: String
        let rate: String
        let mark: String
        let isCoreAudio: Bool
    }

    static let leaderMatch = "PULSE"
    static let interfaceKey = "interface"

    private(set) var networkRate = NetworkRate(readings: [], leaderMatch: leaderMatch, now: Date())
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
    private var timer: Timer?

    init() {
        interfaceName = UserDefaults.standard.string(forKey: Self.interfaceKey) ?? "en7"
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var title: String { problem == nil ? networkRate.title : "—" }

    func refresh() {
        interfaces = NetworkInterface.all()
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
        for device in network.snapshot() {
            // A device seen only through mDNS has no rate yet; leave it out of the reading.
            readings.append(NetworkRate.Reading(label: device.label, rate: device.lastHeartbeat == nil ? nil : device.sampleRate,
                                                lastHeard: device.lastHeartbeat))
            labels[device.label] = device.isDVS ? "\(device.label) (DVS)" : device.label
        }
        // Labels are the readings' identity, and the Pi's Dante side is also named USB-AoIP, so these carry a suffix.
        // The menu shows them under a CoreAudio heading, so it drops the suffix.
        var coreAudio: Set<String> = []
        for (name, prefix) in [("Metric Halo", CoreAudioRate.metricHaloUIDPrefix), ("USB-AoIP", CoreAudioRate.usb16x16UIDPrefix)] {
            guard let device = CoreAudioRate.findDevice(uidPrefix: prefix) else { continue }
            let label = "\(name) (CoreAudio)"
            readings.append(NetworkRate.Reading(label: label, rate: CoreAudioRate.nominalRate(of: device)))
            labels[label] = name
            coreAudio.insert(label)
        }
        networkRate = NetworkRate(readings: readings, leaderMatch: Self.leaderMatch, now: now)

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
        networkRate = NetworkRate(readings: [], leaderMatch: Self.leaderMatch, now: Date())
        rows = []
    }

    private func close() {
        network?.stop()
        network = nil
    }
}
