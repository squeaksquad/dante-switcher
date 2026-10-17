import XCTest
@testable import DanteSyncCore

/// Fixtures are real packets captured on the studio network on 2026-10-16.
final class DantePacketsTests: XCTestCase {
    let controllerMAC: [UInt8] = [0x4C, 0xEA, 0x41, 0x63, 0x33, 0x8F]

    func testSetSampleRateMatchesDanteControllerCapture() {
        let packet = DantePackets.setSampleRate(44100, controllerMAC: controllerMAC, sequence: 0x1282)
        XCTAssertEqual(hex(packet), "ffff0028128200004cea4163338f0000417564696e617465073e008100000064000000010000ac44")
    }

    func testClockStatusQueryMatchesNetaudio() {
        let packet = DantePackets.clockStatusQuery(controllerMAC: controllerMAC, sequence: 0x000A)
        let expected = "ffff005c000a00004cea4163338f0000417564696e617465073a002100000064" + String(repeating: "00", count: 60)
        XCTAssertEqual(hex(packet), expected)
    }

    func testHeartbeatCarriesDeviceIDAndRate() {
        let d2 = bytes("fffe00b86cfa0000001dc1fffe6152f1417564696e6174650008000110000000001c80010004001060c60000fffec70f000000000000000000000000002480000004000460c600000010000000010010000663c400074edf0000000000000000001c80020004001060c60000000200000002000000180000fefeacac002080030004001460c6000000020000001800000000ac440000001000000000001c80040004001060c6000000020000001400000000000000000000")
        XCTAssertEqual(DantePackets.parseHeartbeat(d2), .init(deviceID: "001dc1fffe6152f1", sampleRate: 44100))
    }

    func testHeartbeatRejectsSettingsFrames() {
        XCTAssertNil(DantePackets.parseHeartbeat(DantePackets.setSampleRate(48000, controllerMAC: controllerMAC, sequence: 1)))
    }

    func testClockStatusDistinguishesLockedFromMismatched() {
        let header = "ffff00f0178c0000001dc11d27dc0000417564696e617465"
        let mismatched = bytes(header + "0731002000000000000200060001017900000000001dc11d27dc0000001dc11d27dc0000001dc11d27dc0000000100340006000002b4000000030d400000000200000000000000000000000000000000000000020060000c0000000c00a80020")
        let matched = bytes(header + "07310020000000000002000600010129000006df001dc11d27dc0000001dc11d27dc0000001dc11d27dc0000000100340006000002b4000000030d400000000200000000000000000000000000000000000000030060000c0000000c00a80020")
        XCTAssertEqual(DantePackets.parseClockStatus(mismatched), .init(wordClockStateCode: 2, stratum: 121))
        XCTAssertEqual(DantePackets.parseClockStatus(matched), .init(wordClockStateCode: 3, stratum: 41))
        XCTAssertTrue(DantePackets.parseClockStatus(matched)!.wordClockValid)
    }

    func testRateBands() {
        XCTAssertEqual(SampleRate.band(44100), SampleRate.band(48000))
        XCTAssertLessThan(SampleRate.band(48000), SampleRate.band(96000))
        XCTAssertLessThan(SampleRate.band(96000), SampleRate.band(192000))
    }

    private func bytes(_ hex: String) -> [UInt8] {
        var out = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }
}
