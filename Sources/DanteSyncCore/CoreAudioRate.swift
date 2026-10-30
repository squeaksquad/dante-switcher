import CoreAudio
import Foundation

/// Reads and sets CoreAudio devices' rates: the clock master (the Metric Halo) and the
/// USB-AoIP (the Pi's UAC2 gadget, named USB 16x16 until 2026-10-30, which bridges to the Inferno Dante device). Phase 0
/// showed one NominalSampleRate callback per change, including changes made in MIOConsole3d.
public enum CoreAudioRate {
    public static let metricHaloUIDPrefix = "com.mhlabs.mhlink."
    /// The gadget's UID is `AppleUSBAudioEngine:<vendor>:<product>:<serial>:<interfaces>`.
    public static let usb16x16UIDPrefix = "AppleUSBAudioEngine:Bryan DiMaio:USB-AoIP:"
    /// The gadget's UID before the rename (and after its rollback); matched as the same device.
    public static let usb16x16LegacyUIDPrefix = "AppleUSBAudioEngine:Bryan DiMaio:USB 16x16:"

    /// Whether `uid` starts with `prefix`; the gadget's prefix also matches its legacy one.
    public static func uid(_ uid: String, matches prefix: String) -> Bool {
        uid.hasPrefix(prefix) || (prefix == usb16x16UIDPrefix && uid.hasPrefix(usb16x16LegacyUIDPrefix))
    }

    public enum SetError: Error, CustomStringConvertible {
        case unsupported(rate: Int, offered: [Int])
        case status(OSStatus)

        public var description: String {
            switch self {
            case .unsupported(let rate, let offered):
                return "\(formatRate(rate)) not offered (device offers \(offered.map(formatRate).joined(separator: ", ")))"
            case .status(let status): return "CoreAudio error \(status)"
            }
        }
    }

    public struct Device {
        public let id: AudioObjectID
        public let name: String
        public let uid: String
    }

    public static func findDevice(uidPrefix: String = metricHaloUIDPrefix) -> Device? {
        for id in allDevices() {
            let uid = string(id, kAudioDevicePropertyDeviceUID)
            if self.uid(uid, matches: uidPrefix) {
                return Device(id: id, name: string(id, kAudioObjectPropertyName), uid: uid)
            }
        }
        return nil
    }

    public static func nominalRate(of device: Device) -> Int? {
        var address = globalAddress(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return Int(rate.rounded())
    }

    /// The Dante rates the device offers (`AvailableNominalSampleRates`, ranges included).
    public static func availableRates(of device: Device) -> [Int] {
        var address = globalAddress(kAudioDevicePropertyAvailableNominalSampleRates)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device.id, &address, 0, nil, &size) == noErr else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        return SampleRate.all.filter { rate in
            ranges.contains { Double(rate) >= $0.mMinimum.rounded() && Double(rate) <= $0.mMaximum.rounded() }
        }
    }

    /// Asks the device for a rate. CoreAudio applies it asynchronously; `waitForRate` confirms it.
    public static func setNominalRate(_ rate: Int, on device: Device) throws {
        let offered = availableRates(of: device)
        guard offered.contains(rate) else { throw SetError.unsupported(rate: rate, offered: offered) }
        var address = globalAddress(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        let status = AudioObjectSetPropertyData(device.id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else { throw SetError.status(status) }
    }

    /// How long a rate change on this device must settle before an app starts audio on it:
    /// `usb882Settle` for the USB-AoIP at 88.2k (see `SyncOptions.usb882Settle`), else 0.
    public static func settleTime(_ rate: Int, uid: String, usb882Settle: TimeInterval) -> TimeInterval {
        rate == 88200 && self.uid(uid, matches: usb16x16UIDPrefix) ? max(0, usb882Settle) : 0
    }

    /// Polls until the device reads `rate`, or the timeout passes. Re-finds the device by UID
    /// each time, because a rate change can make a USB device re-enumerate under a new ID.
    public static func waitForRate(_ rate: Int, uid: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let device = findDevice(uidPrefix: uid), nominalRate(of: device) == rate { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return false
    }

    private static func allDevices() -> [AudioObjectID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
