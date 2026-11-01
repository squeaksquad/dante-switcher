import XCTest
@testable import DanteSyncCore

final class SyncOptionsTests: XCTestCase {
    func testTheLeadingSourceIsTheOneNamedElseTheFirst() {
        var options = SyncOptions()
        XCTAssertEqual(options.leadingSource, .metricHalo)
        options.source = RateSource.usbAoIP.uidMatch
        XCTAssertEqual(options.leadingSource, .usbAoIP)
        options.source = "gone"
        XCTAssertEqual(options.leadingSource, .metricHalo)
        options.sources = []
        XCTAssertNil(options.leadingSource)
    }

    func testTheLeaderMatchesByIDOrName() {
        var pulse = DanteNetwork.Device(id: "001dc1fffe5a1b2c")
        pulse.name = "FF-PULSE-16-DX"
        var options = SyncOptions()
        XCTAssertTrue(options.isLeader(pulse))
        options.leaderMatch = "001DC1FFFE5A1B2C"
        XCTAssertTrue(options.isLeader(pulse))
        options.leaderMatch = "D2USB"
        XCTAssertFalse(options.isLeader(pulse))
        options.leaderMatch = nil
        XCTAssertFalse(options.isLeader(pulse))
    }

    func testTheStoredMatchIsTheFamilyPrefixOrTheWholeUID() {
        XCTAssertEqual(CoreAudioRate.stableMatch(for: "com.mhlabs.mhlink.ULN8-1234"), CoreAudioRate.metricHaloUIDPrefix)
        XCTAssertEqual(CoreAudioRate.stableMatch(for: CoreAudioRate.usb16x16LegacyUIDPrefix + "AUDDEV001:1,2"),
                       CoreAudioRate.usb16x16UIDPrefix)
        XCTAssertEqual(CoreAudioRate.stableMatch(for: "AppleUSBAudioEngine:RME:Fireface UCX II:12345:1"),
                       "AppleUSBAudioEngine:RME:Fireface UCX II:12345:1")
    }
}
