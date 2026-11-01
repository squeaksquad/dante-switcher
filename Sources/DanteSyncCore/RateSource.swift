import Foundation

/// A CoreAudio device whose rate changes move the network. Any selected source can lead: a
/// change on one is followed, and every other selected source is set to match.
public struct RateSource: Codable, Equatable {
    public var name: String
    /// A UID prefix (`CoreAudioRate.uid(_:matches:)`); `CoreAudioRate.stableMatch(for:)` makes one.
    public var uidMatch: String
    /// The Dante network's clock comes from this device (the Metric Halo's MADI clocks the Pulse):
    /// when another source leads, it is set and verified before any Dante device, and the sync
    /// stops if it does not change. A source without it is set alongside the Dante devices.
    public var clocksNetwork: Bool

    public init(name: String, uidMatch: String, clocksNetwork: Bool) {
        self.name = name
        self.uidMatch = uidMatch
        self.clocksNetwork = clocksNetwork
    }

    /// The studio this was built for, and the CLI's default: the Metric Halo clocks the Pulse
    /// over MADI; the USB-AoIP (the Pi's gadget) takes its Dante set and its USB rate as one change.
    public static let metricHalo = RateSource(name: "Metric Halo", uidMatch: CoreAudioRate.metricHaloUIDPrefix, clocksNetwork: true)
    public static let usbAoIP = RateSource(name: "USB-AoIP", uidMatch: CoreAudioRate.usb16x16UIDPrefix, clocksNetwork: false)

    public func find() -> CoreAudioRate.Device? {
        CoreAudioRate.findDevice(uidPrefix: uidMatch)
    }
}
