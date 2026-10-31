import DanteSyncCore
import Foundation

let usage = """
Usage:
  dante-sync status [--interface en7] [--wait 4]
      Read-only: Metric Halo and USB-AoIP rates, every Dante device's rate from heartbeats,
      leader lock state.
  dante-sync sync [--rate 48000] [--source mh|usb-aoip] [--exclude NAME]... [--leader PULSE]
                  [--leave-master] [--no-usb] [--dry-run] [--allow-band-up] [--interface en7]
                  [--usb882-settle 10]
      Set the Metric Halo first if it is not the source, then the leader, wait for word-clock
      lock, then every other Dante device and the USB-AoIP together, each verified.
      Without --rate, the target is the source's CoreAudio rate (default: the Metric Halo).
      When the USB-AoIP is set to 88.2k, the sync holds --usb882-settle seconds before it
      reports: macOS needs the 88.2k stream settled before an app starts audio on it.
  dante-sync watch [same options as sync, less --rate and --source]
      Follow rate changes on the Metric Halo or the USB-AoIP (a DAW session, Audio MIDI Setup,
      MIOConsole3d): a change that holds for 2 s is synced to everything else, the changed
      device being the source. Ctrl-C stops it.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["status", "sync", "watch"].contains(command) else {
    print(usage)
    exit(2)
}
arguments.removeFirst()

var interfaceName = "en7"
var options = SyncOptions()
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { print("\(flag) needs a value\n\n\(usage)"); exit(2) }
        return arguments.removeFirst()
    }
    switch flag {
    case "--interface": interfaceName = value()
    case "--rate":
        guard let rate = Int(value()) else { print("--rate needs a number in Hz"); exit(2) }
        options.targetRate = rate
    case "--source":
        switch value().lowercased() {
        case "mh", "metric-halo", "metrichalo": options.source = .metricHalo
        case "usb16x16", "usb", "usb-16x16", "usb-aoip": options.source = .usb16x16
        default: print("--source is mh or usb16x16"); exit(2)
        }
    case "--leave-master": options.followMaster = false
    case "--no-usb": options.followUSB16x16 = false
    case "--exclude": options.exclude.append(value())
    case "--leader": options.leaderMatch = value()
    case "--wait": options.discoveryWait = TimeInterval(value()) ?? options.discoveryWait
    case "--usb882-settle": options.usb882Settle = TimeInterval(value()) ?? options.usb882Settle
    case "--dry-run": options.dryRun = true
    case "--allow-band-up": options.allowBandUp = true
    default: print("Unknown option \(flag)\n\n\(usage)"); exit(2)
    }
}

func log(_ message: String) {
    print(message)
    fflush(stdout)
}

func printReport(_ report: SyncReport) {
    log("")
    for result in report.results {
        log("  \(result.device.padding(toLength: 22, withPad: " ", startingAt: 0)) \(result.outcome.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(result.detail)")
    }
    log(report.summary)
}

let network: DanteNetwork
do {
    network = try DanteNetwork(interfaceName: interfaceName)
} catch {
    log("Can't open the Dante network on \(interfaceName): \(error)")
    exit(1)
}
network.start()
let mac = network.interface.mac.map { String(format: "%02x", $0) }.joined(separator: ":")
log("Dante interface \(interfaceName) \(network.interface.ipv4) (\(mac))")

switch command {
case "status":
    if let master = CoreAudioRate.findDevice() {
        log("Clock master \(master.name): \(CoreAudioRate.nominalRate(of: master).map(formatRate) ?? "unknown")")
    } else {
        log("Clock master: no Metric Halo in CoreAudio")
    }
    if let usb = CoreAudioRate.findDevice(uidPrefix: CoreAudioRate.usb16x16UIDPrefix) {
        log("\(usb.name): \(CoreAudioRate.nominalRate(of: usb).map(formatRate) ?? "unknown")"
            + " (offers \(CoreAudioRate.availableRates(of: usb).map(formatRate).joined(separator: ", ")))")
    } else {
        log("USB-AoIP: not in CoreAudio")
    }
    try? await Task.sleep(nanoseconds: UInt64(options.discoveryWait * 1e9))
    let devices = network.snapshot()
    if let leader = devices.first(where: { $0.label.localizedCaseInsensitiveContains(options.leaderMatch) }), let ip = leader.ip {
        let askedAt = Date()
        try? network.requestClockStatus(of: leader)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if let reading = network.clockReading(ip: ip), reading.received > askedAt {
            log("Leader \(leader.label): word clock \(reading.status.wordClockValid ? "LOCKED" : "NOT locked") (state \(reading.status.wordClockStateCode), stratum \(reading.status.stratum))")
        } else {
            log("Leader \(leader.label): no clock-status reply")
        }
    }
    log("")
    log("Device".padding(toLength: 22, withPad: " ", startingAt: 0) + "IP".padding(toLength: 17, withPad: " ", startingAt: 0)
        + "Rate".padding(toLength: 8, withPad: " ", startingAt: 0) + "Port   Heartbeat")
    for device in devices {
        let age = device.lastHeartbeat.map { String(format: "%.1fs ago", Date().timeIntervalSince($0)) } ?? "none"
        log(device.label.padding(toLength: 22, withPad: " ", startingAt: 0)
            + (device.ip ?? "—").padding(toLength: 17, withPad: " ", startingAt: 0)
            + (device.sampleRate.map(formatRate) ?? "—").padding(toLength: 8, withPad: " ", startingAt: 0)
            + "\(device.settingsPort)".padding(toLength: 7, withPad: " ", startingAt: 0)
            + age + (device.isDVS ? "  (DVS)" : ""))
    }

case "sync":
    let report = await SyncEngine(network: network, log: log).run(options)
    printReport(report)
    network.stop()
    exit(report.aborted == nil && !report.results.contains { $0.outcome == .failed } ? 0 : 1)

case "watch":
    func readings() -> [String: Int] {
        var now: [String: Int] = [:]
        for (source, prefix) in [(SyncOptions.Source.metricHalo, CoreAudioRate.metricHaloUIDPrefix),
                                 (.usb16x16, CoreAudioRate.usb16x16UIDPrefix)] {
            if let device = CoreAudioRate.findDevice(uidPrefix: prefix), let rate = CoreAudioRate.nominalRate(of: device) {
                now[source.rawValue] = rate
            }
        }
        return now
    }
    let start = readings()
    log("Watching " + (start.isEmpty ? "(no Metric Halo or USB-AoIP yet)"
        : start.sorted { $0.key < $1.key }.map { "\($0.key) \(formatRate($0.value))" }.joined(separator: ", "))
        + (options.dryRun ? " — dry run, nothing is set" : ""))
    if Set(start.values).count > 1 {
        log("They disagree now; nothing is done until one of them changes.")
    }
    var follower = RateFollower(initial: start)
    while true {
        try? await Task.sleep(nanoseconds: 250_000_000)
        for event in follower.observe(readings(), at: Date()) {
            switch event {
            case .ignored(let source, let rate, let reason):
                log("\(source) → \(formatRate(rate)) not followed: \(reason)")
            case .follow(let decision):
                log("")
                log("\(decision.source) changed to \(formatRate(decision.rate)); syncing everything else")
                if decision.source == SyncOptions.Source.usb16x16.rawValue && decision.rate == 88200 {
                    // The app that set it has likely started audio already, so no hold here can help.
                    log("WARNING: an app set the USB-AoIP to 88.2k. If it started audio within a few seconds,"
                        + " macOS may pass only silence on the USB-AoIP, both ways, until the rate is changed again."
                        + " If so: stop audio on it, set it to 48k, wait 10 s, set 88.2k, wait 10 s, then start audio.")
                }
                var run = options
                run.targetRate = decision.rate
                run.source = SyncOptions.Source(rawValue: decision.source) ?? .metricHalo
                printReport(await SyncEngine(network: network, log: log).run(run))
                follower.finished(readings(), at: Date())
            }
        }
    }

default:
    break
}
network.stop()
