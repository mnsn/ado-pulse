import ADOPulseCore
import Foundation
import Testing
@testable import ADOPulse

/// Started as an app, ADO Pulse reads Notification Center with its own Full Disk Access, which only you can give it:
/// pull requests sent in chats are on exactly while it has that access, turning them off removes it, and if that fails
/// they stay off anyway until the access is gone. These run the store's decisions against a stand-in that never reads
/// Notification Center or changes Full Disk Access.
@MainActor
@Suite struct ChatReadingTests {
    /// A store that has started, as `start()` starts it, without reading Azure DevOps.
    private func launch(_ defaults: UserDefaults, _ fake: FakeChatReading, ownAccess: Bool = true) -> PRStore {
        let store = PRStore(settings: AppSettings(defaults: defaults), mode: .live, chats: fake.reading(ownAccess: ownAccess))
        store.decideChatsAtLaunch()
        store.observeSettings()
        store.updateChatMonitor()
        return store
    }

    /// You turn it on or off in its settings, and the store reacts.
    private func turn(_ store: PRStore, on enabled: Bool, _ fake: FakeChatReading) async {
        let removals = fake.removals
        let monitors = fake.monitorsStarted
        store.settings.chatLinksEnabled = enabled
        await settle { enabled ? fake.monitorsStarted > monitors : fake.removals > removals }
        await store.accessRemoval?.value
    }

    @Test func readsWithItsOwnAccessOnlyWhileItHasIt() {
        let granted = FakeChatReading(access: .granted)
        let store = launch(MemoryDefaults(), granted)
        #expect(store.settings.chatLinksEnabled)
        #expect(granted.monitorsStarted == 1)

        // No access, or another app's (run from a shell): it starts off, and reads nothing.
        for (ownAccess, access) in [(true, AccessStatus.denied), (true, .missing), (false, .granted)] {
            let fake = FakeChatReading(access: access)
            let store = launch(MemoryDefaults(), fake, ownAccess: ownAccess)
            #expect(!store.settings.chatLinksEnabled, "own access: \(ownAccess), \(access)")
            #expect(fake.monitorsStarted == 0, "own access: \(ownAccess), \(access)")
            #expect(fake.removals == 0, "own access: \(ownAccess), \(access)")
        }
    }

    @Test func turningItOffRemovesItsAccess() async {
        let defaults = MemoryDefaults()
        let fake = FakeChatReading(access: .granted)
        let store = launch(defaults, fake)
        await turn(store, on: false, fake)
        #expect(fake.removals == 1)
        #expect(fake.access == .denied)
        #expect(!store.chatAccessToRemove)
        // The access is gone, so nothing needs to keep it off: granting it again turns it on.
        #expect(!store.settings.chatLinksKeptOff)
        #expect(defaults.stored[SettingsKey.chatLinksKeptOff] == nil)

        let next = launch(defaults, fake)
        #expect(!next.settings.chatLinksEnabled)
        #expect(fake.removals == 1)
    }

    @Test func turningItOffWithoutAccessRemovesNothing() async throws {
        // Turned on, then off again before you allowed Full Disk Access.
        let fake = FakeChatReading(access: .denied)
        let store = launch(MemoryDefaults(), fake)
        await turn(store, on: true, fake)
        store.settings.chatLinksEnabled = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.removals == 0)
        #expect(!store.settings.chatLinksKeptOff)
        #expect(!store.chatAccessToRemove)
    }

    /// The safeguard: if removing Full Disk Access fails, the feature stays off anyway, at every launch while the access
    /// is left, and you're asked to remove ADO Pulse in System Settings yourself.
    @Test func ifRemovingTheAccessFailsItStaysOffAndAsksYouToRemoveIt() async {
        for removal in [FakeChatReading.Removal.fails, .seemsToWork] {
            let defaults = MemoryDefaults()
            let fake = FakeChatReading(access: .granted, removal: removal)
            let store = launch(defaults, fake)
            await turn(store, on: false, fake)
            #expect(fake.removals == 1, "\(removal)")
            #expect(store.chatAccessToRemove, "\(removal)")
            #expect(!store.settings.chatLinksEnabled, "\(removal)")
            #expect(defaults.stored[SettingsKey.chatLinksKeptOff] as? Bool == true, "\(removal)")

            // Next launch, macOS still says ADO Pulse has access: it stays off, tries again, and asks again.
            let next = launch(defaults, fake)
            await next.accessRemoval?.value
            #expect(!next.settings.chatLinksEnabled, "\(removal)")
            #expect(fake.monitorsStarted == 1, "\(removal)")
            #expect(fake.removals == 2, "\(removal)")
            #expect(next.chatAccessToRemove, "\(removal)")

            // You removed it.
            fake.access = .denied
            let removed = launch(defaults, fake)
            #expect(!removed.chatAccessToRemove, "\(removal)")
            #expect(!removed.settings.chatLinksKeptOff, "\(removal)")
            #expect(defaults.stored[SettingsKey.chatLinksKeptOff] == nil, "\(removal)")
            #expect(fake.removals == 2, "\(removal)")
        }
    }

    @Test func turningItOnAgainUndoesKeepingItOff() async {
        let defaults = MemoryDefaults()
        let fake = FakeChatReading(access: .granted, removal: .fails)
        let store = launch(defaults, fake)
        await turn(store, on: false, fake)
        #expect(store.chatAccessToRemove)

        await turn(store, on: true, fake)
        #expect(!store.chatAccessToRemove)
        #expect(!store.settings.chatLinksKeptOff)
        #expect(defaults.stored[SettingsKey.chatLinksKeptOff] == nil)
        #expect(fake.monitorsStarted == 2)
    }

    /// Run from a shell, it reads with that app's access, which isn't ADO Pulse's to remove.
    @Test func withAShellsAccessItRemovesNothing() async throws {
        let fake = FakeChatReading(access: .granted)
        let store = launch(MemoryDefaults(), fake, ownAccess: false)
        await turn(store, on: true, fake)
        #expect(fake.monitorsStarted == 1)
        store.settings.chatLinksEnabled = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.removals == 0)
        #expect(!store.settings.chatLinksKeptOff)
        #expect(store.accessRemoval == nil)
    }

    /// `--render`, the demo and tests make stores that read nothing: only the app's live store is given Notification
    /// Center, and the demo never reads it.
    @Test func otherStoresReadNothing() {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .live)
        #expect(!store.chats.usesOwnAccess)
        #expect(store.chats.access() == .denied)
        #expect(store.chats.monitor { _ in } == nil)
        store.decideChatsAtLaunch()
        #expect(!settings.chatLinksEnabled)

        let fake = FakeChatReading(access: .granted)
        let demo = PRStore(settings: settings, mode: .demo, chats: fake.reading(ownAccess: true))
        demo.decideChatsAtLaunch()
        settings.chatLinksEnabled = true
        demo.updateChatMonitor()
        #expect(fake.monitorsStarted == 0)
    }
}
