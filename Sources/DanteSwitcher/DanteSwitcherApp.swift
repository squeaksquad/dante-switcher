import DanteSyncCore
import ServiceManagement
import SwiftUI

@main
struct DanteSwitcherApp: App {
    @State private var monitor = RateMonitor()
    @State private var updates = UpdateChecker()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: monitor, updates: updates)
        } label: {
            Text(monitor.title).monospacedDigit()
        }
        Window("Dante Switcher Settings", id: "settings") {
            SettingsView(monitor: monitor)
        }
        .windowResizability(.contentSize)
        Window("Dante Switcher Log", id: "log") {
            LogView(monitor: monitor)
        }
    }
}

struct MenuContent: View {
    @Bindable var monitor: RateMonitor
    let updates: UpdateChecker

    var body: some View {
        Section {
            if let problem = monitor.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
            } else if let rate = monitor.networkRate.rate {
                let behind = monitor.networkRate.mismatched.count
                Text(behind == 0 ? "All devices at \(formatRate(rate))" : "\(behind) not at \(formatRate(rate))")
                // The leader's own row says "clock leader"; the header only speaks up when it is missing.
                if monitor.networkRate.leader == nil {
                    Text(monitor.leaderID == nil ? "No clock leader chosen" : "Clock leader not heard")
                }
            } else {
                Text("Listening on \(monitor.interfaceName)… no Dante devices heard yet")
            }
        }
        DeviceSection(title: "Dante Devices", rows: monitor.rows.filter { !$0.isCoreAudio })
        DeviceSection(title: "Rate Sources on This Mac", rows: monitor.rows.filter(\.isCoreAudio))
        Section {
            if monitor.sources.isEmpty {
                Text("Choose a rate source in Settings to follow or sync")
            } else {
                Toggle("Follow Rate Changes", isOn: $monitor.follow)
                if monitor.syncing {
                    Text("Syncing…")
                } else {
                    Menu("Sync Now To") {
                        Section("Set every device to the rate of") {
                            ForEach(monitor.sources, id: \.uidMatch) { source in
                                Button(source.name) { monitor.syncNow(to: source) }
                            }
                        }
                    }
                    .disabled(monitor.problem != nil)
                }
            }
            // Menu items don't wrap, so long text goes inside the submenu or the log window, not in a title.
            if let report = monitor.lastReport, let at = monitor.lastReportAt {
                let failed = report.aborted != nil || report.results.contains { $0.outcome == .failed || $0.outcome == .skipped }
                Menu {
                    Text(report.summary)
                    Divider()
                    ForEach(Array(report.results.enumerated()), id: \.offset) { _, result in
                        Button("\(result.device)   \(result.outcome.rawValue)   \(result.detail)") {}
                    }
                } label: {
                    Label("Last Sync \(at.formatted(date: .omitted, time: .shortened))",
                          systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle")
                }
            }
        }
        Section {
            if let release = updates.available {
                Button {
                    updates.open(release)
                } label: {
                    Label("Update Available: \(release.version)…", systemImage: "arrow.down.circle")
                }
            } else {
                Button("Check for Updates…") { Task { await updates.check(manual: true) } }
                    .disabled(updates.checking)
            }
            OpenWindowButton(title: "Settings…", id: "settings")
                .keyboardShortcut(",")
            OpenWindowButton(title: "Show Log…", id: "log")
                .disabled(monitor.log.isEmpty)
        }
        Button("Quit Dante Switcher") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// A menu section with a heading (the menu draws its separators); nothing when it has no rows.
/// The rows are buttons that do nothing: a plain Text item is drawn disabled, in the same gray
/// as the heading, so the heading would not stand out. The icon carries the status, the rate
/// sits at the end of the name.
struct DeviceSection: View {
    let title: String
    let rows: [RateMonitor.Row]

    var body: some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in
                    Button {} label: {
                        Label("\(row.label)   \(row.rate)" + Self.note(row), systemImage: Self.symbol(row))
                    }
                }
            }
        }
    }

    static func symbol(_ row: RateMonitor.Row) -> String {
        switch row.status {
        case .mismatched: "exclamationmark.triangle"
        case .noHeartbeat: "questionmark.circle"
        case .leader: "star.fill"
        case .atRate: row.clocksNetwork ? "metronome" : "checkmark.circle"
        }
    }

    static func note(_ row: RateMonitor.Row) -> String {
        switch row.status {
        case .leader: "   clock leader"
        case .noHeartbeat: "   not heard"
        case .mismatched, .atRate: row.clocksNetwork ? "   clocks Dante" : ""
        }
    }
}

/// The settings that used to be submenus, with room to say what each one does.
struct SettingsView: View {
    @Bindable var monitor: RateMonitor
    @State private var showAllDevices = false

    var body: some View {
        Form {
            Section {
                Picker("Clock leader", selection: Binding(get: { monitor.leaderID }, set: { id in
                    monitor.setLeader(monitor.danteDevices.first { $0.id == id })
                })) {
                    Text("None").tag(String?.none)
                    ForEach(monitor.danteDevices, id: \.id) { device in
                        Text(device.label).tag(String?.some(device.id))
                    }
                    if let id = monitor.leaderID, let name = monitor.leaderName, !monitor.danteDevices.contains(where: { $0.id == id }) {
                        Text("\(name) (not heard)").tag(String?.some(id))
                    }
                }
                Picker("Network interface", selection: $monitor.interfaceName) {
                    ForEach(monitor.interfaces, id: \.name) { interface in
                        Text("\(interface.name)  \(interface.ipv4)" + (interface.isLinkLocal ? "  (link-local)" : "")).tag(interface.name)
                    }
                    if !monitor.interfaces.contains(where: { $0.name == monitor.interfaceName }) {
                        Text("\(monitor.interfaceName)  (no address)").tag(monitor.interfaceName)
                    }
                }
            } header: {
                Text("Dante")
            } footer: {
                Footnote("The clock leader is set first, and the others wait until it has locked at the new rate. "
                         + "With None, every Dante device is set at once. The interface is the Mac's port on the Dante network.")
            }

            Section {
                // Chosen sources first, in the order chosen; an unplugged one stays chosen, so it shows to be removed.
                ForEach(monitor.sources, id: \.uidMatch) { source in
                    let device = monitor.audioDevices.first { CoreAudioRate.uid($0.uid, matches: source.uidMatch) }
                    SourceRow(name: device == nil ? "\(source.name) (not connected)" : source.name, source: source, monitor: monitor,
                              isOn: Binding(get: { true }, set: { _ in monitor.removeSource(source) }))
                }
                let others = monitor.audioDevices.filter { !monitor.isSource($0) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                DisclosureGroup("Other audio devices (\(others.count))", isExpanded: $showAllDevices) {
                    ForEach(others, id: \.uid) { device in
                        SourceRow(name: device.name, source: nil, monitor: monitor,
                                  isOn: Binding(get: { false }, set: { _ in monitor.toggleSource(device) }))
                    }
                }
            } header: {
                Text("Rate Sources")
            } footer: {
                Footnote("When the sample rate changes on a checked device, every Dante device and the other sources follow. "
                         + "Turn on Clocks Dante for a device whose clock drives the Dante leader (through MADI or word clock): "
                         + "it is set first, and the sync stops if it doesn't change.")
            }

            Section("General") {
                LaunchAtLogin(monitor: monitor)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 360, idealHeight: 560, maxHeight: 900)
    }
}

/// A section footer: secondary, leading-aligned (a grouped form centers it otherwise).
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One CoreAudio device: whether it is a source, and whether it clocks the Dante network.
struct SourceRow: View {
    let name: String
    let source: RateSource?
    let monitor: RateMonitor
    let isOn: Binding<Bool>

    var body: some View {
        HStack {
            Toggle(name, isOn: isOn)
            Spacer()
            Toggle("Clocks Dante", isOn: Binding(get: { source?.clocksNetwork ?? false },
                                                 set: { on in source.map { monitor.setClocksNetwork($0, on) } }))
                .disabled(source == nil)
        }
        .toggleStyle(.checkbox)
    }
}

struct OpenWindowButton: View {
    let title: String
    let id: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: id)
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

/// On while macOS has the login item enabled or waiting for approval; off otherwise.
struct LaunchAtLogin: View {
    let monitor: RateMonitor

    var body: some View {
        let pending = monitor.loginStatus == .requiresApproval
        Toggle("Launch at Login" + (pending ? " (approve in System Settings)" : ""),
               isOn: Binding(get: { monitor.loginStatus == .enabled || pending }, set: { monitor.setLaunchAtLogin($0) }))
            .disabled(!monitor.isInstalled)
        if !monitor.isInstalled {
            Text("Move Dante Switcher to Applications to launch it at login.")
                .foregroundStyle(.secondary)
        } else if pending {
            Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
        }
    }
}
