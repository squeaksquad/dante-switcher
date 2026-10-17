import Foundation

public enum SampleRate {
    public static let all = [44100, 48000, 88200, 96000, 176400, 192000]

    /// Channel capacity is tied to the rate band: 1× (44.1/48), 2× (88.2/96), 4× (176.4/192).
    public static func band(_ rate: Int) -> Int {
        rate <= 48000 ? 1 : rate <= 96000 ? 2 : 4
    }
}

/// Wire formats verified against captures from this network (see PLAN.md).
public enum DantePackets {
    static let magic = Array("Audinate".utf8)

    /// Settings frame: `ffff <len16> <seq16> 0000 <controller mac6> 0000 "Audinate" <record>`.
    public static func settingsFrame(record: [UInt8], controllerMAC: [UInt8], sequence: UInt16) -> [UInt8] {
        precondition(controllerMAC.count == 6, "controller MAC must be 6 bytes")
        var packet: [UInt8] = [0xFF, 0xFF]
        packet += be16(UInt16(24 + record.count))
        packet += be16(sequence)
        packet += [0, 0]
        packet += controllerMAC
        packet += [0, 0]
        packet += magic
        packet += record
        return packet
    }

    /// Opcode 0x0081, flag 1 + rate. Sent to port 8700 (hardware) or 38700 (DVS); no reply.
    public static func setSampleRate(_ rate: Int, controllerMAC: [UInt8], sequence: UInt16) -> [UInt8] {
        let record: [UInt8] = [0x07, 0x3E, 0x00, 0x81] + be32(100) + be32(1) + be32(UInt32(rate))
        return settingsFrame(record: record, controllerMAC: controllerMAC, sequence: sequence)
    }

    /// Clock-control (0x0021, profile 0x073a) with every change mask cleared: a read-only query.
    /// The device answers with a 0x0020 clock-status record on multicast 224.0.0.231:8702.
    public static func clockStatusQuery(controllerMAC: [UInt8], sequence: UInt16) -> [UInt8] {
        let record: [UInt8] = [0x07, 0x3A, 0x00, 0x21] + be32(100) + [UInt8](repeating: 0, count: 60)
        return settingsFrame(record: record, controllerMAC: controllerMAC, sequence: sequence)
    }

    public struct Heartbeat: Equatable {
        public let deviceID: String
        public let sampleRate: Int?
    }

    /// Heartbeat on 224.0.0.233:8708: 32-byte header (`fffe`, length, 8-byte device ID at 8),
    /// then records `[len16][type16][sub16][payloadLen16][sub bytes][payload]`.
    /// Record 0x8003 carries the device's sample rate at payload + 8.
    public static func parseHeartbeat(_ data: [UInt8]) -> Heartbeat? {
        guard data.count >= 32, data[0] == 0xFF, data[1] == 0xFE, Int(u16(data, 2)) == data.count else { return nil }
        let id = hex(data[8..<16])
        var offset = 32
        var rate: Int?
        while offset + 4 <= data.count {
            let length = Int(u16(data, offset))
            guard length >= 4, length % 4 == 0, offset + length <= data.count else { return nil }
            if u16(data, offset + 2) == 0x8003, length >= 8 {
                let payload = offset + 8 + Int(u16(data, offset + 4))
                if payload + 12 <= offset + length {
                    rate = Int(u32(data, payload + 8))
                }
            }
            offset += length
        }
        return Heartbeat(deviceID: id, sampleRate: rate)
    }

    public struct ClockStatus: Equatable {
        public let wordClockStateCode: UInt8
        public let stratum: UInt8
        /// Code 3 = valid (locked to the external word clock), 2 = invalid.
        public var wordClockValid: Bool { wordClockStateCode == 3 }
    }

    /// 0x0020 clock-status record (revision 0x0731 on the Pulse 16 DX). The record starts after the
    /// 24-byte settings header; stratum is at record + 15, word-clock state at record + 83.
    public static func parseClockStatus(_ data: [UInt8]) -> ClockStatus? {
        let record = 24
        guard data.count >= record + 84, data[0] == 0xFF, data[1] == 0xFF,
              Array(data[16..<24]) == magic, u16(data, record + 2) == 0x0020 else { return nil }
        return ClockStatus(wordClockStateCode: data[record + 83], stratum: data[record + 15])
    }
}

func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
func be32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (24 - 8 * UInt32($0))) & 0xFF) } }
func u16(_ data: [UInt8], _ offset: Int) -> UInt16 { UInt16(data[offset]) << 8 | UInt16(data[offset + 1]) }
func u32(_ data: [UInt8], _ offset: Int) -> UInt32 {
    data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
}
func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}
