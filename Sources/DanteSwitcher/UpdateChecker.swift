import AppKit
import DanteSyncCore
import Foundation
import Observation

/// Asks GitHub for the latest published release at launch and once a day. A newer one shows in
/// the menu, which opens its release page to download the pkg; nothing is downloaded here.
/// Drafts and pre-releases are not "latest", so only a published release is ever offered.
@MainActor @Observable
final class UpdateChecker {
    struct Release {
        let version: ReleaseVersion
        let page: URL
    }

    static let latestURL = URL(string: "https://api.github.com/repos/squeaksquad/dante-switcher/releases/latest")!

    let current = ReleaseVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    /// A release newer than this copy, once one is found.
    private(set) var available: Release?
    private(set) var checking = false
    private var timer: Timer?

    init() {
        Task { await check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { await self?.check(manual: false) }
        }
    }

    /// A manual check says what it found; the daily one stays quiet unless there is an update.
    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let latest = try await fetchLatest()
            if let current, latest.version > current {
                available = latest
                if manual { open(latest) }
            } else {
                available = nil
                if manual { tell("Dante Switcher \(current?.description ?? "") is up to date.") }
            }
        } catch {
            if manual { tell("Couldn't check for updates: \(error.localizedDescription)") }
        }
    }

    func open(_ release: Release) {
        NSWorkspace.shared.open(release.page)
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DanteSwitcher/\(current?.description ?? "?")", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404: no published release yet, or the repository isn't public.
        guard status != 404 else { throw CheckError("no published release found on GitHub.") }
        guard status == 200 else { throw CheckError("GitHub answered \(status).") }
        struct Body: Decodable {
            let tag_name: String
            let html_url: URL
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        guard let version = ReleaseVersion(body.tag_name) else { throw CheckError("Unreadable release tag \(body.tag_name)") }
        return Release(version: version, page: body.html_url)
    }

    private func tell(_ message: String) {
        // A menu bar app is never frontmost on its own, so the alert would open behind others.
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    struct CheckError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}
