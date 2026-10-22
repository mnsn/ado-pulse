import ADOPulseCore
import Foundation
@testable import ADOPulse

/// Stands in for Notification Center and Full Disk Access: says whether ADO Pulse has access, and counts what the store
/// asks of it. It never reads Notification Center or runs `tccutil`.
@MainActor
final class FakeChatReading {
    /// What removing the access does: what `tccutil` reports, and whether the access is gone after.
    enum Removal {
        case works, fails
        /// `tccutil` says it worked, yet macOS still gives ADO Pulse access.
        case seemsToWork
    }

    var access: AccessStatus
    var removal: Removal
    private(set) var removals = 0
    private(set) var monitorsStarted = 0

    init(access: AccessStatus, removal: Removal = .works) {
        self.access = access
        self.removal = removal
    }

    /// With ADO Pulse's own permissions, as when it's started as an app, or a shell's.
    func reading(ownAccess: Bool) -> ChatReading {
        ChatReading(
            usesOwnAccess: ownAccess,
            access: { self.access },
            removeAccess: {
                self.removals += 1
                if self.removal == .works { self.access = .denied }
                return self.removal != .fails
            },
            monitor: { _ in
                self.monitorsStarted += 1
                return nil
            }
        )
    }
}

/// Everything the preferences would hold, as text: what any program running as you could read there.
func readable(_ defaults: MemoryDefaults) -> String {
    defaults.stored.map { key, value in
        "\(key)=" + ((value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)")
    }.sorted().joined(separator: "\n")
}

/// Waits, up to two seconds, for what the store does on the main queue, such as reacting to a setting.
@MainActor
func settle(until condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
