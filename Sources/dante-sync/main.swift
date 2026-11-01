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
      Without --rate, the target is the source's CoreAudio rate (default: the Metric Halo),
      and the sync follows it even into a higher rate band (44.1/48 → 88.2/96 → 176.4/192),
      printing a note that channel counts may drop. An explicit --rate into a higher band is
      refused unless --allow-band-up is given; on a follow, --allow-band-up changes nothing.
      When the USB-AoIP is set to 88.2k, the sync holds --usb882-settle seconds before it
      reports: macOS needs the 88.2k stream settled before an app starts audio on it.
  dante-sync watch [same options as sync, less --rate and --source]
      Follow rate changes on the Metric Halo or the USB-AoIP (a DAW session, Audio MIDI Setup,
      MIOConsole3d): a change that holds for 2 s is synced to everything else, the changed
      device being the source; like sync --source, it follows across a rate band with a note.
      Ctrl-C stops it.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["status", "sync", "watch"].contains(command) else {
    print(usage)
    exit(2)
}
arguments.removeFirst()

var interfaceName = "en7"
var options = SyncOptions()
var leaveMaster = false
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
        case "mh", "metric-halo", "metrichalo": options.source = RateSource.metricHalo.uidMatch
        case "usb16x16", "usb", "usb-16x16", "usb-aoip": options.source = RateSource.usbAoIP.uidMatch
        default: print("--source is mh or usb-aoip"); exit(2)
        }
    case "--leave-master": leaveMaster = true
    case "--no-usb": options.sources.removeAll { $0 == .usbAoIP && options.source != $0.uidMatch }
    case "--exclude": options.exclude.append(value())
    case "--leader": options.leaderMatch = value()
    case "--wait": options.discoveryWait = TimeInterval(value()) ?? options.discoveryWait
    case "--usb882-settle": options.usb882Settle = TimeInterval(value()) ?? options.usb882Settle
    case "--dry-run": options.dryRun = true
    case "--allow-band-up": options.allowBandUp = true
    default: print("Unknown option \(flag)\n\n\(usage)"); exit(2)
    }
}

// After parsing, so --source given after --leave-master still counts.
if leaveMaster {
    options.sources.removeAll { $0 == .metricHalo && options.source != $0.uidMatch }
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
    for source in options.sources {
        if let device = source.find() {
            log("\(device.name): \(CoreAudioRate.nominalRate(of: device).map(formatRate) ?? "unknown")"
                + " (offers \(CoreAudioRate.availableRates(of: device).map(formatRate).joined(separator: ", ")))")
        } else {
            log("\(source.name): not in CoreAudio")
        }
    }
    try? await Task.sleep(nanoseconds: UInt64(options.discoveryWait * 1e9))
    let devices = network.snapshot()
    if let leader = devices.first(where: options.isLeader), let ip = leader.ip {
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
    await RateWatcher(network: network, options: options, log: log, report: printReport).run()

default:
    break
}
network.stop()
