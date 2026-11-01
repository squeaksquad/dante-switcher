import XCTest
@testable import DanteSyncCore

final class NetworkRateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func heard(_ label: String, _ rate: Int?, secondsAgo: TimeInterval = 1) -> NetworkRate.Reading {
        NetworkRate.Reading(label: label, rate: rate, lastHeard: now.addingTimeInterval(-secondsAgo))
    }

    func testAllAgreeShowsTheRate() {
        let rate = NetworkRate(readings: [heard("FF-PULSE-16-DX", 48000), heard("D2USB-6152f1", 48000),
                                          NetworkRate.Reading(label: "Metric Halo", rate: 48000)],
                               leaderMatch: "PULSE", now: now)
        XCTAssertEqual(rate.rate, 48000)
        XCTAssertEqual(rate.leader, "FF-PULSE-16-DX")
        XCTAssertEqual(rate.title, "48k")
    }

    /// 2026-10-17: DVS and the D2USB left at 44.1k while the Pulse, the MH and the Pi were at 48k.
    func testTheLeaderWinsOverTheMajority() {
        let rate = NetworkRate(readings: [heard("FF-PULSE-16-DX", 48000), heard("Bryans-MBP-M2-Max", 44100),
                                          heard("D2USB-6152f1", 44100)],
                               leaderMatch: "PULSE", now: now)
        XCTAssertEqual(rate.rate, 48000)
        XCTAssertEqual(rate.mismatched.map(\.label), ["Bryans-MBP-M2-Max", "D2USB-6152f1"])
        XCTAssertEqual(rate.title, "48k ⚠")
    }

    func testWithoutALeaderTheMajorityWins() {
        let rate = NetworkRate(readings: [heard("Bryans-MBP-M2-Max", 96000), heard("D2USB-6152f1", 96000),
                                          heard("USB-16x16-Inferno", 48000)],
                               leaderMatch: "PULSE", now: now)
        XCTAssertEqual(rate.rate, 96000)
        XCTAssertNil(rate.leader)
        XCTAssertEqual(rate.mismatched.map(\.label), ["USB-16x16-Inferno"])
    }

    func testAMajorityTieGoesToTheHigherRate() {
        let readings = [heard("A", 44100), heard("B", 88200)]
        XCTAssertEqual(NetworkRate(readings: readings, leaderMatch: "PULSE", now: now).rate, 88200)
        XCTAssertEqual(NetworkRate(readings: readings.reversed(), leaderMatch: "PULSE", now: now).rate, 88200)
    }

    func testAStaleDeviceIsNeitherTheRateNorAMismatch() {
        let rate = NetworkRate(readings: [heard("FF-PULSE-16-DX", 44100, secondsAgo: 30), heard("D2USB-6152f1", 48000)],
                               leaderMatch: "PULSE", now: now)
        XCTAssertEqual(rate.rate, 48000)
        XCTAssertNil(rate.leader)
        XCTAssertTrue(rate.mismatched.isEmpty)
        XCTAssertEqual(rate.stale.map(\.label), ["FF-PULSE-16-DX"])
    }

    func testADeviceWithNoRateIsNotAMismatch() {
        let rate = NetworkRate(readings: [heard("FF-PULSE-16-DX", 48000), heard("Bryans-MBP-M2-Max", nil)],
                               leaderMatch: "PULSE", now: now)
        XCTAssertEqual(rate.title, "48k")
    }

    func testNothingHeardShowsADash() {
        XCTAssertEqual(NetworkRate(readings: [], leaderMatch: "PULSE", now: now).title, "—")
        XCTAssertEqual(NetworkRate(readings: [], leaderMatch: "PULSE", now: now).rate, nil)
    }
}
