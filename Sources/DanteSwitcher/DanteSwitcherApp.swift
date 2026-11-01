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
        Picker("Dante Interface", selection: $monitor.interfaceName) {
            ForEach(monitor.interfaces, id: \.name) { interface in
                Text("\(interface.name)  \(interface.ipv4)" + (interface.isLinkLocal ? "  (link-local)" : "")).tag(interface.name)
            }
            if !monitor.interfaces.contains(where: { $0.name == monitor.interfaceName }) {
                Text("\(monitor.interfaceName)  (no address)").tag(monitor.interfaceName)
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
