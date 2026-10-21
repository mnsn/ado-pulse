import ADOPulseCore
import AppKit
import UserNotifications

/// Posts macOS notifications; clicking one opens its pull request.
@MainActor
final class Notifier: NSObject {
    private let center: UNUserNotificationCenter?
    private var requestedAuthorization = false
    /// Called when a notification is clicked, with its pull request and link (nil for a summary).
    var onOpen: ((_ key: String?, _ url: URL?) -> Void)?
    /// Called with whether macOS blocks ADO Pulse's notifications (turned off in System Settings).
    var onBlockedChange: ((Bool) -> Void)?

    override init() {
        // Only an app bundle can post notifications; a bare `swift run` binary can't.
        center = Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    var isAvailable: Bool { center != nil }

    /// Asks once, the first time there's something to announce or the setting is turned on.
    func requestAuthorization() {
        guard let center, !requestedAuthorization else {
            refreshStatus()
            return
        }
        requestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Log.app.info("Notifications \(granted ? "allowed" : "not allowed", privacy: .public)\(error.map { ": \($0.localizedDescription)" } ?? "", privacy: .public)")
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    /// Checks whether notifications are turned off for ADO Pulse in System Settings.
    func refreshStatus() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            let blocked = settings.authorizationStatus == .denied
            Task { @MainActor in self?.onBlockedChange?(blocked) }
        }
    }

    /// System Settings › Notifications, at ADO Pulse.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(AppSettings.domain)") {
            NSWorkspace.shared.open(url)
        }
    }

    func post(_ notes: [PulseNotification]) {
        guard let center, !notes.isEmpty else { return }
        requestAuthorization()
        for note in notes {
            let content = UNMutableNotificationContent()
            content.title = note.title
            if let subtitle = note.subtitle { content.subtitle = subtitle }
            content.body = note.body
            content.sound = .default
            content.threadIdentifier = note.url?.absoluteString ?? "ado-pulse"
            var info: [String: String] = [:]
            if let url = note.url { info["url"] = url.absoluteString }
            if let key = note.key { info["pullRequest"] = key.description }
            content.userInfo = info
            let request = UNNotificationRequest(identifier: note.id, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    Log.app.error("Couldn't post a notification: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let link = (info["url"] as? String).flatMap(URL.init(string:))
        let key = info["pullRequest"] as? String
        await MainActor.run {
            onOpen?(key, link)
        }
    }
}
