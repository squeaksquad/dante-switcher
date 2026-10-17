// Throwaway Phase 0 probe: logs every CoreAudio nominal-sample-rate change, on every
// device, plus devices appearing/disappearing. Read-only.
//
//     swift scripts/rate_watch.swift            # devices matching "Metric Halo" are marked ★
//     swift scripts/rate_watch.swift "MIO"      # different match string
//
// Leave it running, change rates from MIOConsole3d / Audio MIDI Setup / a DAW, Ctrl-C to stop.

import CoreAudio
import Foundation

let match = CommandLine.arguments.dropFirst().first ?? "Metric Halo"
let queue = DispatchQueue(label: "rate-watch")
let started = Date()
var watched = Set<AudioObjectID>()
var lastRate = [AudioObjectID: Double]()
var names = [AudioObjectID: String]()

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return "?" }
    return value.takeRetainedValue() as String
}

func nominalRate(_ id: AudioObjectID) -> Double? {
    var addr = address(kAudioDevicePropertyNominalSampleRate)
    var rate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr ? rate : nil
}

func allDevices() -> [AudioObjectID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func log(_ message: String) {
    let stamp = String(format: "%8.3f", Date().timeIntervalSince(started))
    print("[\(stamp)s] \(message)")
    fflush(stdout)
}

func label(_ id: AudioObjectID) -> String {
    let name = names[id] ?? "?"
    return (name.localizedCaseInsensitiveContains(match) ? "★ " : "  ") + name
}

func watch(_ id: AudioObjectID) {
    guard !watched.contains(id) else { return }
    watched.insert(id)
    let manufacturer = stringProperty(id, kAudioObjectPropertyManufacturer)
    names[id] = "\(stringProperty(id, kAudioObjectPropertyName)) [\(manufacturer)]"
    lastRate[id] = nominalRate(id)
    log("\(label(id))  uid=\(stringProperty(id, kAudioDevicePropertyDeviceUID))  rate=\(lastRate[id].map { String(Int($0)) } ?? "?")")

    var rateAddr = address(kAudioDevicePropertyNominalSampleRate)
    AudioObjectAddPropertyListenerBlock(id, &rateAddr, queue) { _, _ in
        let new = nominalRate(id)
        let old = lastRate[id]
        lastRate[id] = new
        log("\(label(id))  RATE \(old.map { String(Int($0)) } ?? "?") -> \(new.map { String(Int($0)) } ?? "?")")
    }
    var aliveAddr = address(kAudioDevicePropertyDeviceIsAlive)
    AudioObjectAddPropertyListenerBlock(id, &aliveAddr, queue) { _, _ in
        log("\(label(id))  isAlive changed")
    }
}

func rescan() {
    let current = Set(allDevices())
    for gone in watched.subtracting(current) {
        log("\(label(gone))  REMOVED")
        watched.remove(gone)
    }
    for id in current.subtracting(watched).sorted() {
        if initialScanDone { log("ADDED device \(id)") }
        watch(id)
    }
}

var initialScanDone = false
queue.sync { rescan(); initialScanDone = true }
var devicesAddr = address(kAudioHardwarePropertyDevices)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, queue) { _, _ in rescan() }
if !names.values.contains(where: { $0.localizedCaseInsensitiveContains(match) }) {
    log("no device matching \"\(match)\" yet; waiting for it to appear")
}
log("watching \(watched.count) devices; Ctrl-C to stop")
dispatchMain()
