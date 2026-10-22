import ADOPulseCore
import Foundation
import Testing
@testable import ADOPulse

/// Pull requests sent in chats: the links found are kept in the app's preferences only while the feature is on, and
/// turning it off forgets them there too, not only in memory.
@MainActor
@Suite struct ChatLinkSettingsTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A preferences suite of the test's own, removed afterwards.
    private func withPreferences(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ADOPulseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func link(_ number: Int, sentAt: Date) -> ChatLink {
        ChatLink(link: PullRequestLink(organization: "contoso", project: "Shop", repository: "web", number: number),
                 app: "com.microsoft.teams2", sender: "Dana Whitfield", sentAt: sentAt, notificationKey: "n\(number)")
    }

    /// Sent longer ago than links are kept.
    private var expired: Date { now.addingTimeInterval(-ChatLinkState.keepFor - 3_600) }

    private func save(_ links: [ChatLink], enabled: Bool, in defaults: UserDefaults) throws {
        defaults.set(enabled, forKey: SettingsKey.chatLinksEnabled)
        defaults.set(try JSONEncoder().encode(ChatLinkState(links: links)), forKey: SettingsKey.chatLinks)
    }

    private func saved(in defaults: UserDefaults) throws -> [Int]? {
        try defaults.data(forKey: SettingsKey.chatLinks).map {
            try JSONDecoder().decode(ChatLinkState.self, from: $0).links.map(\.key.number)
        }
    }

    @Test func turningItOffForgetsLinksThatHadExpired() throws {
        try withPreferences { defaults in
            // Every link saved has expired by the time ADO Pulse starts.
            try save([link(1, sentAt: expired)], enabled: true, in: defaults)
            let settings = AppSettings(defaults: defaults, now: now)
            #expect(settings.chatLinks.links.isEmpty)

            settings.chatLinksEnabled = false
            #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
        }
    }

    @Test func turningItOffForgetsWhatThePreferencesHaveNotOnlyWhatsInMemory() throws {
        try withPreferences { defaults in
            defaults.set(true, forKey: SettingsKey.chatLinksEnabled)
            let settings = AppSettings(defaults: defaults, now: now)
            // Links in the preferences that the settings don't have.
            try save([link(1, sentAt: now)], enabled: true, in: defaults)
            #expect(settings.chatLinks.links.isEmpty)

            settings.chatLinksEnabled = false
            #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
        }
    }

    @Test func turningItOffForgetsTheLinksFound() throws {
        try withPreferences { defaults in
            defaults.set(true, forKey: SettingsKey.chatLinksEnabled)
            let settings = AppSettings(defaults: defaults, now: now)
            #expect(settings.addChatLinks([link(1, sentAt: now)], now: now))
            let stored = try saved(in: defaults)
            #expect(stored == [1])

            settings.chatLinksEnabled = false
            #expect(settings.chatLinks.links.isEmpty)
            #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
        }
    }

    @Test func linksThatExpiredGoFromThePreferencesWhenItStarts() throws {
        try withPreferences { defaults in
            try save([link(1, sentAt: expired), link(2, sentAt: now)], enabled: true, in: defaults)
            let settings = AppSettings(defaults: defaults, now: now)
            #expect(settings.chatLinks.links.map(\.key.number) == [2])
            let stored = try saved(in: defaults)
            #expect(stored == [2])
        }
        try withPreferences { defaults in
            try save([link(1, sentAt: expired)], enabled: true, in: defaults)
            _ = AppSettings(defaults: defaults, now: now)
            #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
        }
    }

    @Test func linksLeftWhileItsOffGoWhenItStarts() throws {
        try withPreferences { defaults in
            try save([link(1, sentAt: now)], enabled: false, in: defaults)
            let settings = AppSettings(defaults: defaults, now: now)
            #expect(settings.chatLinks.links.isEmpty)
            #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
        }
    }

    @Test func nothingIsKeptWhileItsOff() throws {
        try withPreferences { defaults in
            let settings = AppSettings(defaults: defaults, now: now)
            #expect(!settings.chatLinksEnabled)
            #expect(!settings.addChatLinks([link(1, sentAt: now)], now: now))
            #expect(settings.chatLinks.links.isEmpty)
            #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
        }
    }
}
