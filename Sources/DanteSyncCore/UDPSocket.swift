import Darwin
import Foundation

public struct SocketError: Error, CustomStringConvertible {
    public let description: String
    init(_ call: String) { description = "\(call): \(String(cString: strerror(errno)))" }
}

/// Minimal BSD UDP socket. Multicast listeners share their port with Dante's own daemons
/// (DVS binds 8708/8702 too), so SO_REUSEPORT is always set, and they bind the group address
/// itself so that a daemon holding the port with SO_REUSEADDR alone still lets them in.
final class UDPSocket {
    private let fd: Int32
    private var source: DispatchSourceRead?

    init(port: UInt16, bindAddress: String?, joinGroup group: String? = nil, interfaceAddress: String? = nil) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = Self.address(bindAddress.map { inet_addr($0) } ?? in_addr_t(0), port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); throw SocketError("bind \(bindAddress ?? "*"):\(port)") }

        if let group, let interfaceAddress {
            var request = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(group)),
                                  imr_interface: in_addr(s_addr: inet_addr(interfaceAddress)))
            guard setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
                close(fd)
                throw SocketError("join \(group) on \(interfaceAddress)")
            }
        }
    }

    deinit {
        source?.cancel()
        close(fd)
    }

    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws {
        var address = Self.address(inet_addr(host), port)
        let sent = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == bytes.count else { throw SocketError("sendto \(host):\(port)") }
    }

    func startReceiving(on queue: DispatchQueue, _ handler: @escaping (_ data: [UInt8], _ sourceIP: String) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [fd] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { return }
            handler(Array(buffer[0..<count]), String(cString: inet_ntoa(from.sin_addr)))
        }
        source.resume()
        self.source = source
    }

    private static func address(_ ip: in_addr_t, _ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = ip
        return address
    }
}

public struct NetworkInterface {
    public let name: String
    public let ipv4: String
    public let mac: [UInt8]

    /// Every interface with an IPv4 address and a MAC, for the app's interface menu.
    public static func all() -> [NetworkInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var names: [String] = []
        var cursor = list
        while let entry = cursor {
            let name = String(cString: entry.pointee.ifa_name)
            if !names.contains(name) { names.append(name) }
            cursor = entry.pointee.ifa_next
        }
        return names.compactMap(lookup)
    }

    public var isLinkLocal: Bool { ipv4.hasPrefix("169.254.") }

    public static func lookup(_ name: String) -> NetworkInterface? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }

        var ipv4: String?
        var mac: [UInt8]?
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == name, let address = entry.pointee.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4 = String(cString: inet_ntoa($0.pointee.sin_addr)) }
            case AF_LINK:
                address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
                    let nameLength = Int(link.pointee.sdl_nlen)
                    guard link.pointee.sdl_alen == 6 else { return }
                    // sdl_data starts 8 bytes into sockaddr_dl; the MAC follows the interface name.
                    let data = UnsafeRawPointer(link).advanced(by: 8 + nameLength)
                    mac = Array(UnsafeRawBufferPointer(start: data, count: 6))
                }
            default:
                break
            }
        }
        guard let ipv4, let mac else { return nil }
        return NetworkInterface(name: name, ipv4: ipv4, mac: mac)
    }
}
