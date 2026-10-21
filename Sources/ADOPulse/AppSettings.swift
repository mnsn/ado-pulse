import ADOPulseCore
import Combine
import Foundation

/// User preferences and what you've seen, persisted in UserDefaults.
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
    @Published private(set) var seen: SeenState

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

    func markSeen<S: Sequence>(_ keys: S, at date: Date = Date()) where S.Element == PRKey {
        markSeen(keys.map { ($0, date) })
    }

    /// Each pull request seen up to its own time.
    func markSeen(_ entries: [(key: PRKey, date: Date)]) {
        var updated = seen
        for entry in entries { updated.markSeen([entry.key], at: entry.date) }
        guard updated != seen else { return }
        seen = updated
        persistSeen()
    }

    /// Forgets pull requests that are no longer listed and were last seen over two months ago.
    func pruneSeen(keeping keys: Set<PRKey>, now: Date = Date()) {
        var updated = seen
        updated.prune(keeping: keys, olderThan: now.addingTimeInterval(-60 * 86_400))
        guard updated != seen else { return }
        seen = updated
        persistSeen()
    }

    /// Replaces the seen state, for the demo.
    func useSeenState(_ state: SeenState) {
        seen = state
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
}
