import ADOPulseCore
import Combine
import Foundation

/// User preferences and what you've seen, persisted in UserDefaults. Nothing from Notification Center goes there: the
/// links people sent you in chats, and what you've seen of the pull requests listed only because of them, stay in
/// memory, since any program running as you can read the preferences.
@MainActor
final class AppSettings: ObservableObject {
    /// The app's preferences domain, which the command line reads too.
    nonisolated static let domain = "com.asaf.ADOPulse"

    /// The app's preferences, also from the command line. Inside the app bundle that's the standard defaults:
    /// macOS won't open your own domain as a suite.
    nonisolated static var appDefaults: UserDefaults? {
        Bundle.main.bundleIdentifier == domain ? .standard : UserDefaults(suiteName: domain)
    }

    enum Placement: String, CaseIterable, Identifiable {
        case desktop, floating
        var id: String { rawValue }
        var title: String {
            switch self {
            case .desktop: return "On Desktop (Behind Windows)"
            case .floating: return "Floating (Above Windows)"
            }
        }
    }

    enum WidgetSize: String, CaseIterable, Identifiable {
        case compact, medium, large
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var width: CGFloat { self == .compact ? 290 : 330 }
        var rows: Int {
            switch self {
            case .compact: return 2
            case .medium: return 4
            case .large: return 8
            }
        }
    }

    static let refreshChoices: [(seconds: Int, title: String)] = [
        (60, "Every Minute"), (120, "Every 2 Minutes"), (300, "Every 5 Minutes"),
    ]
    static let keepDoneChoices: [(hours: Int, title: String)] = [
        (4, "4 Hours"), (24, "1 Day"), (72, "3 Days"),
    ]
    static let idleChoices: [(days: Int, title: String)] = [
        (7, "1 Week"), (14, "2 Weeks"), (30, "1 Month"), (0, "Never"),
    ]

    typealias Key = SettingsKey

    private let defaults: UserDefaults

    @Published var showWidget: Bool {
        didSet { defaults.set(showWidget, forKey: Key.showWidget) }
    }
    @Published var placement: Placement {
        didSet { defaults.set(placement.rawValue, forKey: Key.placement) }
    }
    @Published var widgetSize: WidgetSize {
        didSet { defaults.set(widgetSize.rawValue, forKey: Key.widgetSize) }
    }
    @Published var refreshSeconds: Int {
        didSet { defaults.set(refreshSeconds, forKey: Key.refreshSeconds) }
    }
    /// How long completed and abandoned pull requests stay in Done (unless opened sooner).
    @Published var keepDoneHours: Int {
        didSet { defaults.set(keepDoneHours, forKey: Key.keepDoneHours) }
    }
    /// Pull requests without activity for this many days move to Idle; 0 never.
    @Published var idleDays: Int {
        didSet { defaults.set(idleDays, forKey: Key.idleDays) }
    }
    @Published var notifications: Bool {
        didSet { defaults.set(notifications, forKey: Key.notifications) }
    }
    /// Summaries written on this Mac by Apple Intelligence.
    @Published var summaries: Bool {
        didSet { defaults.set(summaries, forKey: Key.summaries) }
    }
    /// Adds the To Review count to the menu bar.
    @Published var showToReview: Bool {
        didSet { defaults.set(showToReview, forKey: Key.showToReview) }
    }
    /// The organizations to watch.
    @Published var organizations: [String] {
        didSet { defaults.set(organizations, forKey: Key.organizations) }
    }
    /// Every organization you belong to, as last found.
    @Published var knownOrganizations: [String] {
        didSet { defaults.set(knownOrganizations, forKey: Key.knownOrganizations) }
    }
    @Published var hasDiscovered: Bool {
        didSet { defaults.set(hasDiscovered, forKey: Key.hasDiscovered) }
    }
    /// Looks for pull request links in the notifications other apps post, such as Teams. Off by default: it needs Full
    /// Disk Access. Not a preference, which any program running as you could set: started as an app, ADO Pulse turns it
    /// on when it has its own Full Disk Access (`PRStore`), and you turn it on or off in its settings. Turning it off
    /// forgets every link found.
    @Published var chatLinksEnabled: Bool {
        didSet {
            if !chatLinksEnabled { forgetChatLinks() }
        }
    }
    /// The links found so far: who sent which pull request, in which app and when. Never the messages. They're kept in
    /// memory only, and only while the feature is on: after a restart, ADO Pulse finds again only those whose
    /// notifications Notification Center still has.
    @Published private(set) var chatLinks: ChatLinkState
    /// You turned Pull Requests Sent in Chats off, and ADO Pulse may still have its Full Disk Access: it stays off,
    /// whatever that access, until the access is gone or you turn it on again. A preference can hold it, since it can
    /// only stop ADO Pulse reading.
    @Published var chatLinksKeptOff: Bool {
        didSet {
            if chatLinksKeptOff {
                defaults.set(true, forKey: Key.chatLinksKeptOff)
            } else {
                defaults.removeObject(forKey: Key.chatLinksKeptOff)
            }
        }
    }
    /// ADO Pulse could read Notification Center before: if it can't now, it was probably rebuilt with
    /// another signature, and has to be added to Full Disk Access again.
    @Published var chatAccessWasGranted: Bool {
        didSet { defaults.set(chatAccessWasGranted, forKey: Key.chatAccessWasGranted) }
    }
    /// What the account signed in now has seen.
    @Published private(set) var seen: SeenState
    /// When you last looked at each pull request that's listed only because someone sent it to you
    /// (`PRKey.description`), in memory only, like the links: in the preferences, it would say which pull requests
    /// people sent you.
    @Published private(set) var seenSentInChats: [String: Date] = [:]
    /// What the other accounts you've signed in with have seen.
    private var otherSeen: [String: SeenState]

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        showWidget = defaults.object(forKey: Key.showWidget) as? Bool ?? true
        placement = defaults.string(forKey: Key.placement).flatMap(Placement.init) ?? .desktop
        widgetSize = defaults.string(forKey: Key.widgetSize).flatMap(WidgetSize.init) ?? .medium
        refreshSeconds = Self.choice(defaults.integer(forKey: Key.refreshSeconds), in: Self.refreshChoices.map(\.seconds), default: 60)
        keepDoneHours = Self.choice(defaults.integer(forKey: Key.keepDoneHours), in: Self.keepDoneChoices.map(\.hours), default: 24)
        idleDays = Self.choice(defaults.object(forKey: Key.idleDays) as? Int ?? -1, in: Self.idleChoices.map(\.days), default: 14)
        notifications = defaults.object(forKey: Key.notifications) as? Bool ?? true
        summaries = defaults.object(forKey: Key.summaries) as? Bool ?? true
        showToReview = defaults.bool(forKey: Key.showToReview)
        organizations = defaults.stringArray(forKey: Key.organizations) ?? []
        knownOrganizations = defaults.stringArray(forKey: Key.knownOrganizations) ?? []
        hasDiscovered = defaults.bool(forKey: Key.hasDiscovered)
        chatLinksEnabled = false
        chatLinks = ChatLinkState()
        chatAccessWasGranted = defaults.bool(forKey: Key.chatAccessWasGranted)
        // Earlier versions kept the switch, and the links found, in plain preferences: any program running as you could
        // read the links, and turn the switch on. Both go, whatever they said; a switch turned off still keeps the
        // feature off, in case ADO Pulse kept its Full Disk Access.
        let legacySwitch = defaults.object(forKey: Key.legacyChatLinksEnabled) as? Bool
        let keptOff = defaults.bool(forKey: Key.chatLinksKeptOff) || legacySwitch == false
        chatLinksKeptOff = keptOff
        defaults.removeObject(forKey: Key.legacyChatLinksEnabled)
        defaults.removeObject(forKey: Key.legacyChatLinks)
        if keptOff { defaults.set(true, forKey: Key.chatLinksKeptOff) }

        otherSeen = defaults.data(forKey: Key.otherSeen).flatMap { try? JSONDecoder().decode([String: SeenState].self, from: $0) } ?? [:]
        if let data = defaults.data(forKey: Key.seen), let stored = try? JSONDecoder().decode(SeenState.self, from: data) {
            seen = stored
        } else {
            seen = SeenState.firstRun(now: now)
            persistSeen()
        }
    }

    private static func choice(_ value: Int, in choices: [Int], default fallback: Int) -> Int {
        choices.contains(value) ? value : fallback
    }

    var engineConfiguration: PulseEngine.Configuration {
        PulseEngine.Configuration(
            organizations: organizations,
            interval: TimeInterval(refreshSeconds),
            keepDoneFor: TimeInterval(keepDoneHours) * 3_600,
            inactiveAfter: idleDays > 0 ? TimeInterval(idleDays) * 86_400 : nil
        )
    }

    var classifierOptions: ClassifierOptions {
        ClassifierOptions(
            inactiveAfter: idleDays > 0 ? TimeInterval(idleDays) * 86_400 : nil,
            keepDoneFor: TimeInterval(keepDoneHours) * 3_600
        )
    }

    func markSeen<S: Sequence>(_ keys: S, at date: Date = Date(), sentInChats: Set<PRKey> = []) where S.Element == PRKey {
        markSeen(keys.map { ($0, date) }, sentInChats: sentInChats)
    }

    /// Each pull request seen up to its own time. Those in `sentInChats`, listed only because someone sent them to
    /// you, are remembered in memory only, and leave the preferences if an earlier version saved them there.
    func markSeen(_ entries: [(key: PRKey, date: Date)], sentInChats: Set<PRKey> = []) {
        keepSeenInMemory(sentInChats)
        var updated = seen
        var inMemory = seenSentInChats
        for entry in entries {
            if sentInChats.contains(entry.key) {
                inMemory[entry.key.description] = max(entry.date, inMemory[entry.key.description] ?? .distantPast)
            } else {
                updated.markSeen([entry.key], at: entry.date)
            }
        }
        if inMemory != seenSentInChats { seenSentInChats = inMemory }
        guard updated != seen else { return }
        seen = updated
        persistSeen()
    }

    /// When you last looked at a pull request, as far as ADO Pulse remembers: in the preferences, or in memory.
    func seenCutoff(for key: PRKey) -> Date {
        max(seen.cutoff(for: key), seenSentInChats[key.description] ?? .distantPast)
    }

    /// Moves what the preferences say you've seen of these pull requests, listed only because someone sent them to
    /// you, into memory. Earlier versions kept that in the preferences.
    func keepSeenInMemory(_ keys: Set<PRKey>) {
        let saved = keys.compactMap { key in seen.seenAt[key.description].map { (key: key.description, date: $0) } }
        guard !saved.isEmpty else { return }
        var inMemory = seenSentInChats
        var updated = seen
        for entry in saved {
            inMemory[entry.key] = max(entry.date, inMemory[entry.key] ?? .distantPast)
            updated.seenAt[entry.key] = nil
        }
        seenSentInChats = inMemory
        seen = updated
        persistSeen()
    }

    /// Forgets pull requests that are no longer listed and were last seen over two months ago.
    func pruneSeen(keeping keys: Set<PRKey>, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-60 * 86_400)
        let kept = Set(keys.map(\.description))
        let inMemory = seenSentInChats.filter { kept.contains($0.key) || $0.value > cutoff }
        if inMemory != seenSentInChats { seenSentInChats = inMemory }
        var updated = seen
        updated.prune(keeping: keys, olderThan: cutoff)
        guard updated != seen else { return }
        seen = updated
        persistSeen()
    }

    /// Keeps newly found links, in memory, while the feature is on. Returns whether there were any.
    @discardableResult
    func addChatLinks(_ found: [ChatLink], now: Date = Date()) -> Bool {
        guard chatLinksEnabled else { return false }
        var updated = chatLinks
        let changed = updated.merge(ChatLinkState.canonical(found, organizations: organizations))
        let pruned = updated.prune(now: now)
        guard changed || pruned else { return false }
        chatLinks = updated
        return changed
    }

    /// Forgets every link found, and what you've seen of the pull requests listed only because of them.
    func forgetChatLinks() {
        if !chatLinks.links.isEmpty { chatLinks = ChatLinkState() }
        if !seenSentInChats.isEmpty { seenSentInChats = [:] }
    }

    /// Replaces the seen state, for the demo and for pictures.
    func useSeenState(_ state: SeenState, others: [String: SeenState] = [:]) {
        otherSeen = others
        seen = state
    }

    /// Switches what you've seen to the account signed in now, keeping the last one's for when it's back. Returns
    /// whether another account was signed in before.
    func useAccount(_ account: String, now: Date = Date()) -> Bool {
        var book = SeenBook(current: seen, others: otherSeen)
        let switched = book.signIn(account, now: now)
        // What the last account saw of pull requests sent in chats was its own, and is kept in memory only.
        if switched, !seenSentInChats.isEmpty { seenSentInChats = [:] }
        guard book.current != seen else { return switched }
        otherSeen = book.others
        seen = book.current
        persistSeen()
        if let data = try? JSONEncoder().encode(otherSeen) {
            defaults.set(data, forKey: Key.otherSeen)
        }
        return switched
    }

    /// Organization names are case-insensitive in Azure DevOps.
    func isWatching(_ name: String) -> Bool {
        organizations.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func toggleOrganization(_ name: String) {
        if isWatching(name) {
            organizations.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        } else {
            organizations = OrganizationDiscovery.merged(organizations, preferring: [name])
        }
    }

    private func persistSeen() {
        if let data = try? JSONEncoder().encode(seen) {
            defaults.set(data, forKey: Key.seen)
        }
    }
}

/// UserDefaults keys, shared with the command line, which reads them.
enum SettingsKey {
    static let showWidget = "showWidget"
    static let placement = "widgetPlacement"
    static let widgetSize = "widgetSize"
    static let refreshSeconds = "refreshSeconds"
    static let keepDoneHours = "keepDoneHours"
    static let idleDays = "idleDays"
    static let notifications = "notifications"
    static let summaries = "summaries"
    static let showToReview = "showToReviewInMenuBar"
    static let organizations = "organizations"
    static let knownOrganizations = "knownOrganizations"
    static let hasDiscovered = "hasDiscoveredOrganizations"
    static let seen = "seenState"
    /// Keeps Pull Requests Sent in Chats off (`AppSettings.chatLinksKeptOff`): it can't turn it on.
    static let chatLinksKeptOff = "chatLinksKeptOff"
    /// Where earlier versions kept the switch and the links. Nothing writes them now: the app removes them at launch.
    static let legacyChatLinksEnabled = "chatLinksEnabled"
    static let legacyChatLinks = "chatLinks"
    static let chatAccessWasGranted = "chatAccessWasGranted"
    static let otherSeen = "otherAccountsSeenState"
}
