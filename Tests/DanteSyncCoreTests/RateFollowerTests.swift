import XCTest
@testable import DanteSyncCore

final class RateFollowerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    let mh = "Metric Halo", usb = "USB 16x16"

    func testAChangeIsFollowedOnceItHoldsForTheSettleTime() {
        var follower = RateFollower(initial: [mh: 48000, usb: 48000])
        XCTAssertEqual(follower.observe([mh: 48000, usb: 48000], at: at(0.25)), [])
        XCTAssertEqual(follower.observe([mh: 44100, usb: 48000], at: at(1)), [])
        XCTAssertEqual(follower.observe([mh: 44100, usb: 48000], at: at(2.5)), [], "not yet 2 s")
        XCTAssertEqual(follower.observe([mh: 44100, usb: 48000], at: at(3)),
                       [.follow(.init(source: mh, rate: 44100))])
        XCTAssertTrue(follower.busy)
    }

    func testTheUSB16x16IsASourceToo() {
        var follower = RateFollower(initial: [mh: 48000, usb: 48000])
        _ = follower.observe([mh: 48000, usb: 96000], at: at(1))
        XCTAssertEqual(follower.observe([mh: 48000, usb: 96000], at: at(3)),
                       [.follow(.init(source: usb, rate: 96000))])
    }

    func testTheLastChangeWins() {
        var follower = RateFollower(initial: [mh: 48000, usb: 48000])
        _ = follower.observe([mh: 44100, usb: 48000], at: at(1))
        _ = follower.observe([mh: 44100, usb: 96000], at: at(2))
        XCTAssertEqual(follower.observe([mh: 44100, usb: 96000], at: at(3.5)), [], "the second change restarts the settle time")
        XCTAssertEqual(follower.observe([mh: 44100, usb: 96000], at: at(4)),
                       [.follow(.init(source: usb, rate: 96000))])
    }

    func testAChangeUndoneBeforeItSettlesIsNotFollowed() {
        var follower = RateFollower(initial: [mh: 48000])
        _ = follower.observe([mh: 44100], at: at(1))
        _ = follower.observe([mh: 48000], at: at(1.5))
        // Back at the rate everything is at: a sync to 48k would change nothing, and none is asked for
        // until the rate has held for the settle time.
        XCTAssertEqual(follower.observe([mh: 48000], at: at(2)), [])
    }

    func testTheSyncsOwnSetsAreNotFollowed() {
        var follower = RateFollower(initial: [mh: 48000, usb: 48000])
        _ = follower.observe([mh: 44100, usb: 48000], at: at(1))
        XCTAssertEqual(follower.observe([mh: 44100, usb: 48000], at: at(3)), [.follow(.init(source: mh, rate: 44100))])
        // The sync sets the USB 16x16; its change is reported, not followed.
        XCTAssertEqual(follower.observe([mh: 44100, usb: 44100], at: at(4)),
                       [.ignored(source: usb, rate: 44100, reason: "a sync is running")])
        follower.finished([mh: 44100, usb: 44100], at: at(6))
        XCTAssertFalse(follower.busy)
        XCTAssertEqual(follower.observe([mh: 44100, usb: 44100], at: at(20)), [], "nothing changed since")
    }

    func testABounceBackJustAfterASyncIsReportedNotFollowed() {
        var follower = RateFollower(initial: [mh: 44100, usb: 48000])
        follower.finished([mh: 44100, usb: 48000], at: at(0))
        // The USB 16x16 moves again (say a DAW reasserts its own rate) within the cooldown.
        XCTAssertEqual(follower.observe([mh: 44100, usb: 96000], at: at(2)),
                       [.ignored(source: usb, rate: 96000, reason: "within 5 s of the last sync")])
        XCTAssertEqual(follower.observe([mh: 44100, usb: 96000], at: at(10)), [], "absorbed into the baseline, no loop")
        // A real change after the cooldown is followed.
        _ = follower.observe([mh: 88200, usb: 96000], at: at(11))
        XCTAssertEqual(follower.observe([mh: 88200, usb: 96000], at: at(13)), [.follow(.init(source: mh, rate: 88200))])
    }

    func testADevicePluggedInIsNotAChange() {
        var follower = RateFollower(initial: [mh: 48000])
        XCTAssertEqual(follower.observe([mh: 48000, usb: 44100], at: at(1)), [])
        XCTAssertEqual(follower.observe([mh: 48000, usb: 44100], at: at(5)), [])
        // Unplugged and back at another rate: also only recorded.
        _ = follower.observe([mh: 48000], at: at(6))
        XCTAssertEqual(follower.observe([mh: 48000, usb: 96000], at: at(7)), [])
        XCTAssertEqual(follower.observe([mh: 48000, usb: 96000], at: at(10)), [])
    }
}
