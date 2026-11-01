import XCTest
@testable import DanteSyncCore

final class BandUpCheckTests: XCTestCase {
    let domain: [(label: String, rate: Int)] = [("FF-PULSE-16-DX", 48000), ("Bryans-MBP-M2-Max", 48000), ("D2USB-6152f1", 48000)]

    func options(rate: Int? = nil, source: RateSource = .usbAoIP, allowBandUp: Bool = false,
                 followsSource: Bool = false, dryRun: Bool = false) -> SyncOptions {
        var options = SyncOptions()
        options.targetRate = rate
        options.source = source.uidMatch
        options.allowBandUp = allowBandUp
        options.followsSource = followsSource
        options.dryRun = dryRun
        return options
    }

    /// 2026-11-01: the USB-AoIP set to 96k (a Pro Tools session), then `sync --source usb-aoip`.
    func testASourceFollowCrossesUpABandWithoutTheFlag() {
        let check = BandUpCheck(target: 96000, devices: domain, options: options())
        XCTAssertNil(check.abort)
        XCTAssertFalse(check.needsConsent)
    }

    func testAWatchFollowCrossesUpABandWithoutTheFlag() {
        let check = BandUpCheck(target: 96000, devices: domain, options: options(rate: 96000, followsSource: true))
        XCTAssertNil(check.abort)
    }

    func testAnExplicitRateCrossingUpStillRefuses() {
        let check = BandUpCheck(target: 96000, devices: domain, options: options(rate: 96000))
        XCTAssertEqual(check.abort, "96k is a higher rate band than FF-PULSE-16-DX (48k), Bryans-MBP-M2-Max (48k),"
                       + " D2USB-6152f1 (48k); channel counts may drop. Re-run with --allow-band-up to proceed. Nothing changed")
        XCTAssertTrue(check.needsConsent)
        XCTAssertNil(BandUpCheck(target: 96000, devices: domain, options: options(rate: 96000, allowBandUp: true)).abort)
    }

    func testAFollowStillPrintsTheChannelCountWarning() {
        let check = BandUpCheck(target: 96000, devices: domain, options: options())
        XCTAssertEqual(check.note, "NOTE: 96k is a higher rate band than FF-PULSE-16-DX (48k), Bryans-MBP-M2-Max (48k),"
                       + " D2USB-6152f1 (48k); channel counts may drop (following USB-AoIP)")
    }

    func testTheFlagOnAFollowChangesNothing() {
        XCTAssertEqual(BandUpCheck(target: 96000, devices: domain, options: options(allowBandUp: true)),
                       BandUpCheck(target: 96000, devices: domain, options: options()))
    }

    func testSameBandOrDownHasNoNote() {
        XCTAssertEqual(BandUpCheck(target: 44100, devices: domain, options: options(rate: 44100)),
                       BandUpCheck(target: 48000, devices: [], options: options()))
        let down = BandUpCheck(target: 48000, devices: [("FF-PULSE-16-DX", 96000)], options: options(rate: 48000))
        XCTAssertNil(down.abort)
        XCTAssertNil(down.note)
    }
}
