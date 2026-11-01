import DanteSyncCore
import SwiftUI

@main
struct DanteSwitcherApp: App {
    @State private var monitor = RateMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            Text(monitor.title).monospacedDigit()
        }
        Window("Dante Switcher Log", id: "log") {
            LogView(monitor: monitor)
        }
    }
}

struct MenuContent: View {
    @Bindable var monitor: RateMonitor

    var body: some View {
        if let problem = monitor.problem {
            Text(problem)
        } else if let rate = monitor.networkRate.rate {
            Text("Network \(formatRate(rate))" + (monitor.networkRate.leader.map { ", from \($0)" } ?? ", no leader heard"))
            if !monitor.networkRate.mismatched.isEmpty {
                Text("\(monitor.networkRate.mismatched.count) not at \(formatRate(rate))")
            }
        } else {
            Text("No Dante heartbeats on \(monitor.interfaceName) yet")
        }
        DeviceSection(title: "Dante", rows: monitor.rows.filter { !$0.isCoreAudio })
        DeviceSection(title: "CoreAudio", rows: monitor.rows.filter(\.isCoreAudio))
        Section {
            Toggle("Follow Rate Changes", isOn: $monitor.follow)
                .disabled(monitor.sources.isEmpty)
            if monitor.sources.isEmpty {
                Text("Choose a rate source to follow or sync")
            } else if monitor.syncing {
                Text("Syncing…")
            } else {
                Menu("Sync Network To") {
                    ForEach(monitor.sources, id: \.uidMatch) { source in
                        Button(source.name) { monitor.syncNow(to: source) }
                    }
                }
                .disabled(monitor.problem != nil)
            }
            // Menu items don't wrap, so long text goes inside the submenu or the log window, not in a title.
            if let report = monitor.lastReport, let at = monitor.lastReportAt {
                Menu("Last Sync, \(at.formatted(date: .omitted, time: .shortened))") {
                    Text(report.summary)
                    Divider()
                    ForEach(Array(report.results.enumerated()), id: \.offset) { _, result in
                        Button("\(result.device)   \(result.outcome.rawValue)   \(result.detail)") {}
                    }
                }
            }
            if !monitor.log.isEmpty {
                ShowLogButton()
            }
        }
        Section {
            SourcesMenu(monitor: monitor)
            LeaderMenu(monitor: monitor)
        Picker("Dante Interface", selection: $monitor.interfaceName) {
            ForEach(monitor.interfaces, id: \.name) { interface in
                Text("\(interface.name)  \(interface.ipv4)" + (interface.isLinkLocal ? "  (link-local)" : "")).tag(interface.name)
            }
            if !monitor.interfaces.contains(where: { $0.name == monitor.interfaceName }) {
                Text("\(monitor.interfaceName)  (no address)").tag(monitor.interfaceName)
            }
        }
        }
        Divider()
        Button("Quit Dante Switcher") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// A menu section with a heading (the menu draws its separators); nothing when it has no rows.
/// The rows are buttons that do nothing: a plain Text item is drawn disabled, in the same gray
/// as the heading, so the heading would not stand out.
struct DeviceSection: View {
    let title: String
    let rows: [RateMonitor.Row]

    var body: some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in
                    Button("\(row.label)   \(row.rate)" + (row.mark.isEmpty ? "" : "   \(row.mark)")) {}
                }
            }
        }
    }
}

/// Which CoreAudio devices move the network, and which of them clocks it.
struct SourcesMenu: View {
    let monitor: RateMonitor

    var body: some View {
        Menu("Rate Sources") {
            Section("Follow changes on") {
                ForEach(monitor.audioDevices, id: \.uid) { device in
                    Toggle(device.name, isOn: Binding(get: { monitor.isSource(device) }, set: { _ in monitor.toggleSource(device) }))
                }
                // A chosen source that is unplugged stays chosen; show it so it can be removed.
                ForEach(monitor.sources.filter { source in !monitor.audioDevices.contains { CoreAudioRate.uid($0.uid, matches: source.uidMatch) } },
                        id: \.uidMatch) { source in
                    Toggle("\(source.name) (not connected)", isOn: Binding(get: { true }, set: { _ in monitor.removeSource(source) }))
                }
            }
            if !monitor.sources.isEmpty {
                Section("Clocks the Dante network") {
                    ForEach(monitor.sources, id: \.uidMatch) { source in
                        Toggle(source.name, isOn: Binding(get: { source.clocksNetwork }, set: { monitor.setClocksNetwork(source, $0) }))
                    }
                }
            }
        }
    }
}

/// The Dante device set first and waited on for word-clock lock, or none.
struct LeaderMenu: View {
    let monitor: RateMonitor

    var body: some View {
        Menu("Dante Clock Leader" + (monitor.leaderName.map { ": \($0)" } ?? ": None")) {
            Toggle("None (set every Dante device together)",
                   isOn: Binding(get: { monitor.leaderID == nil }, set: { _ in monitor.setLeader(nil) }))
            Divider()
            ForEach(monitor.danteDevices, id: \.id) { device in
                Toggle(device.label, isOn: Binding(get: { monitor.leaderID == device.id }, set: { _ in monitor.setLeader(device) }))
            }
            if let id = monitor.leaderID, let name = monitor.leaderName, !monitor.danteDevices.contains(where: { $0.id == id }) {
                Toggle("\(name) (not heard)", isOn: .constant(true))
            }
        }
    }
}

struct ShowLogButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Log…") {
            openWindow(id: "log")
            // A menu bar app is never frontmost on its own, so the window would open behind others.
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

/// The sync log, wrapped and selectable: menu items cut long lines off.
struct LogView: View {
    let monitor: RateMonitor

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(monitor.log.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear.frame(height: 1).id("end")
            }
            .onAppear { proxy.scrollTo("end") }
            .onChange(of: monitor.log.count) { proxy.scrollTo("end") }
        }
        .frame(minWidth: 560, minHeight: 320)
    }
}
