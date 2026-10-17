import Foundation
import Network

/// Live view of the Dante network, built passively: names from mDNS (`_netaudio-cmc._udp`),
/// addresses and sample rates from multicast heartbeats. Writes are single settings packets.
public final class DanteNetwork {
    public struct Device {
        /// Instance ID (EUI-64). Stable across renames; DVS renamed itself during testing.
        public let id: String
        public var name: String?
        public var model: String?
        public var ip: String?
        public var sampleRate: Int?
        public var lastHeartbeat: Date?

        public var label: String { name ?? id }
        public var isDVS: Bool { model == "DvsMacOs" }
        /// DVS shifts its control ports by +30000 (conmon_server -b=38700 -c=38800).
        public var settingsPort: UInt16 { isDVS ? 38700 : 8700 }
    }

    public struct ClockReading {
        public let status: DantePackets.ClockStatus
        public let received: Date
    }

    public let interface: NetworkInterface
    private let queue = DispatchQueue(label: "dante-network")
    private var devices: [String: Device] = [:]
    private var clockReadings: [String: ClockReading] = [:]
    private var sequence = UInt16.random(in: 1...0x7FFF)
    private let heartbeats: UDPSocket
    private let settingsMulticast: UDPSocket
    private let sender: UDPSocket
    private let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_netaudio-cmc._udp", domain: "local."), using: .udp)

    public init(interfaceName: String) throws {
        guard let interface = NetworkInterface.lookup(interfaceName) else {
            throw SocketError("no IPv4 address/MAC on \(interfaceName)")
        }
        self.interface = interface
        heartbeats = try UDPSocket(port: 8708, bindAddress: nil, joinGroup: "224.0.0.233", interfaceAddress: interface.ipv4)
        settingsMulticast = try UDPSocket(port: 8702, bindAddress: nil, joinGroup: "224.0.0.231", interfaceAddress: interface.ipv4)
        sender = try UDPSocket(port: 0, bindAddress: interface.ipv4)
    }

    public func start() {
        heartbeats.startReceiving(on: queue) { [weak self] data, ip in self?.handleHeartbeat(data, from: ip) }
        settingsMulticast.startReceiving(on: queue) { [weak self] data, ip in self?.handleSettings(data, from: ip) }
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.handleBrowse(results) }
        browser.start(queue: queue)
    }

    public func stop() {
        browser.cancel()
    }

    public func snapshot() -> [Device] {
        queue.sync { devices.values.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending } }
    }

    public func device(id: String) -> Device? {
        queue.sync { devices[id] }
    }

    public func clockReading(ip: String) -> ClockReading? {
        queue.sync { clockReadings[ip] }
    }

    public func setSampleRate(_ rate: Int, on device: Device) throws {
        guard let ip = device.ip else { throw SocketError("\(device.label) has no known address") }
        let packet = DantePackets.setSampleRate(rate, controllerMAC: interface.mac, sequence: nextSequence())
        try sender.send(packet, to: ip, port: device.settingsPort)
    }

    public func requestClockStatus(of device: Device) throws {
        guard let ip = device.ip else { throw SocketError("\(device.label) has no known address") }
        let packet = DantePackets.clockStatusQuery(controllerMAC: interface.mac, sequence: nextSequence())
        try sender.send(packet, to: ip, port: device.settingsPort)
    }

    private func nextSequence() -> UInt16 {
        queue.sync {
            sequence = sequence == 0xFFFF ? 1 : sequence + 1
            return sequence
        }
    }

    private func handleHeartbeat(_ data: [UInt8], from ip: String) {
        guard let heartbeat = DantePackets.parseHeartbeat(data) else { return }
        var device = devices[heartbeat.deviceID] ?? Device(id: heartbeat.deviceID)
        device.ip = ip
        device.lastHeartbeat = Date()
        if let rate = heartbeat.sampleRate { device.sampleRate = rate }
        devices[heartbeat.deviceID] = device
    }

    private func handleSettings(_ data: [UInt8], from ip: String) {
        guard let status = DantePackets.parseClockStatus(data) else { return }
        clockReadings[ip] = ClockReading(status: status, received: Date())
    }

    private func handleBrowse(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  case let .bonjour(txt) = result.metadata,
                  let id = txt["id"]?.lowercased() else { continue }
            var device = devices[id] ?? Device(id: id)
            device.name = name
            device.model = txt["model"]
            devices[id] = device
        }
    }
}

extension DanteNetwork.Device {
    init(id: String) {
        self.init(id: id, name: nil, model: nil, ip: nil, sampleRate: nil, lastHeartbeat: nil)
    }
}
