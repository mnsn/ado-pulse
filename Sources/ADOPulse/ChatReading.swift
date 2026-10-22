import ADOPulseCore
import Foundation

/// How ADO Pulse reads Notification Center for pull requests sent in chats, and whose Full Disk Access that uses. Inert
/// unless the app passes `notificationCenter(_:)`, so `--render`, the demo and tests can't read Notification Center or
/// change Full Disk Access.
struct ChatReading {
    /// Started as an app, ADO Pulse reads with its own Full Disk Access, which only you can give it. Then the feature
    /// is on at launch exactly while it has that access, and turning it off removes that access.
    var usesOwnAccess: Bool
    /// Whether Notification Center's database can be read now.
    var access: @MainActor () -> AccessStatus
    /// Removes ADO Pulse's own Full Disk Access. Returns whether that worked.
    var removeAccess: @MainActor () async -> Bool
    /// Starts watching Notification Center, delivering on the main queue; nil when it can't.
    var monitor: @MainActor (@escaping ChatLinkMonitor.ChangeHandler) -> ChatLinkMonitor?

    /// Reads nothing, and changes nothing.
    static var inert: ChatReading {
        ChatReading(usesOwnAccess: false, access: { .denied }, removeAccess: { false }, monitor: { _ in nil })
    }

    /// Notification Center itself, with the permissions `attribution` says ADO Pulse has.
    static func notificationCenter(_ attribution: Attribution) -> ChatReading {
        ChatReading(
            usesOwnAccess: attribution == .itself,
            access: { DatabaseAccess.check(NotificationCenterDatabase.defaultURL()) },
            removeAccess: { await removeFullDiskAccess() },
            monitor: { onChange in ChatLinkMonitor(deliverOn: .main, onChange: onChange) }
        )
    }

    /// Removes ADO Pulse from Full Disk Access, as − does in System Settings
    /// (`tccutil reset SystemPolicyAllFiles com.asaf.ADOPulse`). Like every program ADO Pulse starts, `tccutil` is
    /// responsible for itself.
    private static func removeFullDiskAccess() async -> Bool {
        guard Bundle.main.bundleIdentifier == AppSettings.domain else { return false }
        do {
            let result = try await ProcessRunner().run(
                URL(fileURLWithPath: "/usr/bin/tccutil"), arguments: ["reset", "SystemPolicyAllFiles", AppSettings.domain],
                environment: [:], timeout: 15
            )
            if result.status != 0 {
                let output = String(decoding: result.stderr + result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                Log.app.error("tccutil couldn't remove Full Disk Access (\(result.status)): \(output, privacy: .public)")
            }
            return result.status == 0
        } catch {
            Log.app.error("Couldn't run tccutil: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
