import ADOPulseCore
import Foundation
import Testing
@testable import ADOPulse

/// Pull requests sent in chats: the links found, with who sent them, and what you've seen of the pull requests listed
/// only because of them, are kept in memory only, since any program running as you can read the preferences; and no
/// preference or launch argument, which any program could set, turns the feature on.
/// Serialized: one test sets the process's argument domain, which every preferences suite reads.
@MainActor
@Suite(.serialized) struct ChatLinkSettingsTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Listed only because Dana sent it.
    private let sentInChat = PRKey("contoso", 7)
    /// One you review.
    private let yours = PRKey("contoso", 9)

    private func link(_ number: Int, sentAt: Date) -> ChatLink {
        ChatLink(link: PullRequestLink(organization: "contoso", project: "Shop", repository: "web", number: number),
                 app: "com.microsoft.teams2", sender: "Dana Whitfield", sentAt: sentAt, notificationKey: "made-up-n\(number)",
                 conversation: "19:dana-and-you@unq.gbl.spaces", messageID: "1792317000000")
    }

    private func enabled(_ defaults: UserDefaults) -> AppSettings {
        let settings = AppSettings(defaults: defaults, now: now)
        settings.chatLinksEnabled = true
        return settings
    }

    private func savedSeen(in defaults: UserDefaults) throws -> SeenState {
        try JSONDecoder().decode(SeenState.self, from: try #require(defaults.data(forKey: SettingsKey.seen)))
    }

    @Test func keepsNothingFromChatsInThePreferences() throws {
        try withPreferences { defaults, suite in
            let settings = enabled(defaults)
            let before = readable(defaults, suite: suite)

            #expect(settings.addChatLinks([link(7, sentAt: now)], now: now))
            settings.markSeen([sentInChat], at: now.addingTimeInterval(60), sentInChats: [sentInChat])
            #expect(settings.chatLinks.links.count == 1)
            #expect(settings.seenCutoff(for: sentInChat) == now.addingTimeInterval(60))

            let after = readable(defaults, suite: suite)
            #expect(after == before)
            for found in ["Dana Whitfield", "dana-and-you", "1792317000000", "made-up-n7", "teams2", "contoso", "chatLinks"] {
                #expect(!after.contains(found), "The preferences say \(found)")
            }
            let saved = try savedSeen(in: defaults)
            #expect(saved.seenAt.isEmpty)
        }
    }

    @Test func remembersWhatYouveSeenOfYourOwnPullRequestsInThePreferences() throws {
        try withPreferences { defaults, _ in
            let settings = enabled(defaults)
            settings.markSeen([(key: sentInChat, date: now), (key: yours, date: now)], sentInChats: [sentInChat])
            let saved = try savedSeen(in: defaults)
            #expect(saved.seenAt.keys.sorted() == ["contoso/9"])
            #expect(settings.seenCutoff(for: sentInChat) == now)
            #expect(settings.seenCutoff(for: yours) == now)

            // The next launch remembers yours, and only those.
            let again = AppSettings(defaults: defaults, now: now)
            #expect(again.seenCutoff(for: yours) == now)
            #expect(again.seenCutoff(for: sentInChat) < now)
        }
    }

    @Test func removesWhatEarlierVersionsSavedAtLaunchWhateverTheSwitchSaid() throws {
        for earlierSwitch in [true, false, nil] {
            try withPreferences { defaults, suite in
                if let earlierSwitch { defaults.set(earlierSwitch, forKey: SettingsKey.legacyChatLinksEnabled) }
                defaults.set(try JSONEncoder().encode(ChatLinkState(links: [link(7, sentAt: now)])), forKey: SettingsKey.legacyChatLinks)

                let settings = AppSettings(defaults: defaults, now: now)
                let saved = defaults.persistentDomain(forName: suite) ?? [:]
                #expect(saved[SettingsKey.legacyChatLinks] == nil)
                #expect(saved[SettingsKey.legacyChatLinksEnabled] == nil)
                #expect(!readable(defaults, suite: suite).contains("Dana Whitfield"))
                #expect(settings.chatLinks.links.isEmpty)
                #expect(!settings.chatLinksEnabled)
                // Turned off before, it stays off, in case ADO Pulse kept its Full Disk Access.
                #expect(settings.chatLinksKeptOff == (earlierSwitch == false))
            }
        }
    }

    @Test func movesWhatAnEarlierVersionSawOfThemIntoMemory() throws {
        try withPreferences { defaults, _ in
            var earlier = SeenState.firstRun(now: now)
            earlier.markSeen([sentInChat, yours], at: now)
            defaults.set(try JSONEncoder().encode(earlier), forKey: SettingsKey.seen)
            let settings = AppSettings(defaults: defaults, now: now)

            settings.keepSeenInMemory([sentInChat])
            #expect(try savedSeen(in: defaults).seenAt.keys.sorted() == ["contoso/9"])
            #expect(settings.seenCutoff(for: sentInChat) == now)
            #expect(settings.seenCutoff(for: yours) == now)
        }
    }

    @Test func turningItOffForgetsTheLinksAndWhatYouSawOfThem() throws {
        try withPreferences { defaults, _ in
            let settings = enabled(defaults)
            #expect(settings.addChatLinks([link(7, sentAt: now)], now: now))
            settings.markSeen([sentInChat], at: now, sentInChats: [sentInChat])

            settings.chatLinksEnabled = false
            #expect(settings.chatLinks.links.isEmpty)
            #expect(settings.seenCutoff(for: sentInChat) < now)
            // And nothing is kept while it's off.
            #expect(!settings.addChatLinks([link(7, sentAt: now)], now: now))
            #expect(settings.chatLinks.links.isEmpty)
        }
    }

    @Test func forgetsLinksThatExpireWhileItRuns() throws {
        try withPreferences { defaults, _ in
            let settings = enabled(defaults)
            #expect(settings.addChatLinks([link(7, sentAt: now)], now: now))
            #expect(!settings.addChatLinks([], now: now.addingTimeInterval(ChatLinkState.keepFor + 60)))
            #expect(settings.chatLinks.links.isEmpty)
        }
    }

    @Test func anotherAccountHasNotSeenThem() throws {
        try withPreferences { defaults, _ in
            let settings = enabled(defaults)
            #expect(!settings.useAccount("avery@contoso.example", now: now))
            settings.markSeen([sentInChat], at: now, sentInChats: [sentInChat])
            #expect(settings.useAccount("sam@contoso.example", now: now))
            #expect(settings.seenCutoff(for: sentInChat) < now)
        }
    }

    /// As the list does it: clearing Needs You, in the demo, keeps what you've seen of the pull request Dana sent you
    /// in memory, and of the others in the preferences.
    @Test func theListKeepsWhatYouveSeenOfPullRequestsSentInChatsInMemory() async throws {
        try await withPreferences { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            let store = PRStore(settings: settings, mode: .demo)
            await store.loadOnce()
            let needsYou = store.items(in: .needsYou)
            let sent = try #require(needsYou.first { $0.role == .linked })
            #expect(needsYou.contains { $0.role != .linked })

            store.clear(.needsYou)
            let saved = try savedSeen(in: defaults)
            #expect(saved.seenAt[sent.key.description] == nil)
            #expect(settings.seenSentInChats[sent.key.description] != nil)
            #expect(Set(saved.seenAt.keys) == Set(needsYou.filter { $0.role != .linked }.map(\.key.description)))
        }
    }

    /// Any program running as you can write the preferences, or start ADO Pulse with `-chatLinksEnabled YES`: neither
    /// turns the feature on, and without ADO Pulse's own Full Disk Access, or run from a shell, nothing is read.
    @Test func aForgedSwitchOrLaunchArgumentDoesntStartReading() throws {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        for forged in ["preference", "argument"] {
            try withPreferences { defaults, _ in
                if forged == "preference" {
                    defaults.set(true, forKey: SettingsKey.legacyChatLinksEnabled)
                } else {
                    UserDefaults.standard.setVolatileDomain(
                        arguments.merging([SettingsKey.legacyChatLinksEnabled: true]) { $1 }, forName: UserDefaults.argumentDomain
                    )
                }
                #expect(defaults.object(forKey: SettingsKey.legacyChatLinksEnabled) as? Bool == true, "\(forged)")
                let settings = AppSettings(defaults: defaults, now: now)
                #expect(!settings.chatLinksEnabled, "\(forged)")

                for (ownAccess, access) in [(true, AccessStatus.denied), (false, .granted)] {
                    let fake = FakeChatReading(access: access)
                    let store = PRStore(settings: settings, mode: .live, chats: fake.reading(ownAccess: ownAccess))
                    store.decideChatsAtLaunch()
                    store.updateChatMonitor()
                    #expect(!settings.chatLinksEnabled, "\(forged), own access: \(ownAccess)")
                    #expect(fake.monitorsStarted == 0, "\(forged), own access: \(ownAccess)")
                }
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            }
        }
    }

    /// Turned off in an earlier version, which kept Full Disk Access: it stays off, and ADO Pulse removes that access.
    @Test func anOldOffKeepsItOffAndRemovesTheAccessLeft() async throws {
        try await withPreferences { defaults, _ in
            defaults.set(false, forKey: SettingsKey.legacyChatLinksEnabled)
            let settings = AppSettings(defaults: defaults, now: now)
            #expect(settings.chatLinksKeptOff)
            #expect(defaults.bool(forKey: SettingsKey.chatLinksKeptOff))

            let fake = FakeChatReading(access: .granted)
            let store = PRStore(settings: settings, mode: .live, chats: fake.reading(ownAccess: true))
            store.decideChatsAtLaunch()
            store.updateChatMonitor()
            await store.accessRemoval?.value
            #expect(!settings.chatLinksEnabled)
            #expect(fake.monitorsStarted == 0)
            #expect(fake.removals == 1)
            #expect(fake.access == .denied)
            // Once it's gone, nothing needs to keep it off.
            #expect(!settings.chatLinksKeptOff)
        }
    }

    /// The command line keeps none of this: it reads neither the links, which only the app has, in memory, nor what's
    /// left of earlier versions' preferences, which only the app removes.
    @Test func theCommandLineNeverReadsTheLinks() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/ADOPulse").standardizedFileURL
        let cli = try String(contentsOf: sources.appendingPathComponent("CLI.swift"), encoding: .utf8)
        for name in ["ChatLinkState", "seenSentInChats", "legacyChatLinks", "chatLinksKeptOff", "setLinkedPullRequests", "linked:"] {
            #expect(!cli.contains(name), "CLI.swift uses \(name)")
        }
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" && file.lastPathComponent != "AppSettings.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("legacyChatLinks"), "\(file.lastPathComponent) reads what earlier versions saved")
        }
    }
}
