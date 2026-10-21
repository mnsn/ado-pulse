import ADOPulseCore
import AppKit
import Combine
import Network

/// Main-thread view model: turns engine snapshots into the sorted, grouped pull request list, and decides
/// what to announce and summarize.
@MainActor
final class PRStore: ObservableObject {
    enum Mode {
        case live
        /// Made-up pull requests (`--demo`).
        case demo
    }

    enum Discovery: Equatable {
        case idle
        case running
        case failed(String)
    }

    @Published private(set) var items: [PRSnapshot] = []
    @Published private(set) var counts = GroupCounts()
    /// Reference time for relative labels; ticks every 15 s.
    @Published private(set) var now = Date()
    @Published private(set) var problem: PulseProblem?
    @Published private(set) var hasLoaded = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var discovery: Discovery = .idle
    @Published private(set) var brief: [BriefItem] = []
    /// Notifications are on in ADO Pulse but turned off for it in System Settings.
    @Published private(set) var notificationsBlocked = false

    let settings: AppSettings
    let summarizer: Summarizer
    let mode: Mode
    private let notifier: Notifier?
    private let tokens = AzureCLITokenProvider()
    private let client: ADOClient
    private var engine: PulseEngine?
    private var state = PulseSnapshot()
    private let startedAt = Date()
    /// The list as of the last refresh, to compare the next one with.
    private var announced: [PRSnapshot]?
    private var delivered: Set<String> = []
    private var lastDiscovery: Date?
    private var discoveryProblem: PulseProblem?
    private var ticker: Timer?
    private var monitor: NWPathMonitor?
    private var isOnline = true
    private var cancellables: Set<AnyCancellable> = []

    init(settings: AppSettings, summarizer: Summarizer = Summarizer(), notifier: Notifier? = nil, mode: Mode = .live) {
        self.settings = settings
        self.summarizer = summarizer
        self.notifier = notifier
        self.mode = mode
        client = ADOClient(tokens: tokens)
        summarizer.isEnabled = settings.summaries
        notifier?.onBlockedChange = { [weak self] blocked in
            guard let self, self.notificationsBlocked != blocked else { return }
            self.notificationsBlocked = blocked
            if blocked { Log.app.info("Notifications are turned off for ADO Pulse in System Settings") }
        }
        // Summaries arrive one at a time; the views read them through the store.
        summarizer.objectWillChange
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
            .store(in: &cancellables)
    }

    var activeItems: [PRSnapshot] { items.filter { $0.group != .idle } }

    /// Loading for the first time, or for organizations just chosen: nothing to show yet.
    var isLoading: Bool {
        guard mode == .live, !settings.organizations.isEmpty else { return false }
        return items.isEmpty && (isRefreshing || !hasLoaded || state.organizations != settings.organizations)
    }

    func items(in group: PRGroup) -> [PRSnapshot] {
        items.filter { $0.group == group }
    }

    var organizations: [String] {
        mode == .demo ? [DemoData.organization] : settings.organizations
    }

    // MARK: Lifecycle

    func start() {
        guard ticker == nil else { return }
        observeSettings()
        let ticker = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker.tolerance = 3
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker

        switch mode {
        case .demo:
            settings.useSeenState(DemoData.seenState(now: now))
            let snapshot = DemoData.snapshot(now: now)
            receive(snapshot)
            // A new comment a few seconds later, so the demo shows a notification too.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                MainActor.assumeIsolated { self?.receive(DemoData.update(snapshot, at: Date())) }
            }
        case .live:
            let engine = PulseEngine(client: client, configuration: settings.engineConfiguration) { [weak self] snapshot in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.receive(snapshot) }
                }
            }
            self.engine = engine
            Task { await engine.start() }
            if settings.organizations.isEmpty && !settings.hasDiscovered {
                discoverOrganizations()
            }
            watchNetworkAndSleep()
        }
    }

    /// Loads once and waits for it (for `--render`).
    func loadOnce() async {
        switch mode {
        case .demo:
            settings.useSeenState(DemoData.seenState(now: now))
            receive(DemoData.snapshot(now: now))
        case .live:
            receive(await PulseEngine.loadOnce(client: client, configuration: settings.engineConfiguration))
        }
    }

    private func observeSettings() {
        Publishers.MergeMany(
            settings.$organizations.map { _ in () }.eraseToAnyPublisher(),
            settings.$refreshSeconds.map { _ in () }.eraseToAnyPublisher(),
            settings.$keepDoneHours.map { _ in () }.eraseToAnyPublisher(),
            settings.$idleDays.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(4)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let configuration = self.settings.engineConfiguration
                if let engine = self.engine { Task { await engine.setConfiguration(configuration) } }
                self.recompute()
            }
        }
        .store(in: &cancellables)

        settings.$seen.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &cancellables)

        settings.$summaries.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    self?.summarizer.isEnabled = enabled
                    self?.recompute()
                }
            }
            .store(in: &cancellables)

        settings.$notifications.dropFirst().filter { $0 }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.notifier?.requestAuthorization() } }
            .store(in: &cancellables)
    }

    private func watchNetworkAndSleep() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.networkChanged(online: online) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "ADOPulse.network", qos: .utility))
        self.monitor = monitor

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.app.info("Woke from sleep: refreshing")
                    self?.refresh()
                }
            }
            .store(in: &cancellables)
    }

    private func networkChanged(online: Bool) {
        defer { isOnline = online }
        if online && !isOnline {
            Log.app.info("Back online: refreshing")
            refresh()
        }
    }

    private func tick() {
        recompute()
        // Retry finding organizations, for example once you've signed in.
        if mode == .live, settings.organizations.isEmpty, !settings.hasDiscovered, discovery != .running,
           Date().timeIntervalSince(lastDiscovery ?? .distantPast) > 60 {
            discoverOrganizations()
        }
    }

    // MARK: Actions

    func refresh() {
        engine?.refresh()
        if mode == .live, settings.organizations.isEmpty, !settings.hasDiscovered, discovery != .running {
            discoverOrganizations()
        }
    }

    /// When the panel opens: refresh unless that just happened.
    func refreshIfStale() {
        guard Date().timeIntervalSince(refreshedAt ?? .distantPast) > 30 else { return }
        refresh()
    }

    /// Opens the pull request (at the comment that needs you) and marks it seen.
    func open(_ item: PRSnapshot) {
        settings.markSeen([item.key], at: max(Date(), item.events.map(\.at).max() ?? .distantPast))
        AzureDevOps.open(item.url)
    }

    /// Opens a pull request from a notification, and marks it seen like a click in the panel.
    func openFromNotification(key: String?, url: URL) {
        if let item = items.first(where: { $0.key.description == key }) {
            open(item)
        } else {
            AzureDevOps.open(url)
        }
    }

    /// Marks a group's pull requests seen: Needs You moves on, Done empties. Each is seen up to what the panel
    /// showed, not up to now, so a comment that arrives before the next refresh still counts as new.
    func clear(_ group: PRGroup) {
        settings.markSeen(items(in: group).map { item in
            (item.key, item.events.map(\.at).max() ?? item.since ?? Date())
        })
    }

    func openPullRequestsPage() {
        AzureDevOps.openPullRequests(organizations: organizations)
    }

    func signIn() {
        if problem == .cliNotFound {
            AzureDevOps.open(AzureDevOps.installCLIPage)
            return
        }
        Task {
            let path = await tokens.executablePath
            AzureDevOps.signIn(azPath: path)
        }
    }

    /// Finds your organizations, and watches the ones where you have pull requests.
    func discoverOrganizations() {
        guard mode == .live, discovery != .running else { return }
        discovery = .running
        lastDiscovery = Date()
        Task {
            do {
                let all = try await OrganizationDiscovery.memberships(client: client)
                let withPullRequests = await OrganizationDiscovery.withPullRequests(all, client: client)
                settings.knownOrganizations = all
                // Keep the ones you chose yourself too, spelled the way Azure DevOps does.
                settings.organizations = OrganizationDiscovery.merged(settings.organizations, preferring: withPullRequests)
                settings.hasDiscovered = true
                discovery = .idle
                discoveryProblem = nil
                Log.app.info("Found \(all.count) organizations, \(withPullRequests.count) with pull requests")
            } catch {
                let message = (error as? ADOError)?.description ?? error.localizedDescription
                discovery = .failed(message)
                discoveryProblem = PulseProblem.from((error as? ADOError) ?? .network(message))
                Log.app.error("Couldn't find organizations: \(message, privacy: .public)")
            }
            recompute()
        }
    }

    // MARK: Updates

    func receive(_ snapshot: PulseSnapshot) {
        state = snapshot
        if refreshedAt != snapshot.refreshedAt { refreshedAt = snapshot.refreshedAt }
        if isRefreshing != snapshot.isRefreshing { isRefreshing = snapshot.isRefreshing }
        if snapshot.hasLoaded && !hasLoaded { hasLoaded = true }
        if snapshot.hasLoaded, !snapshot.isRefreshing, !snapshot.organizations.isEmpty {
            // Ask about notifications once there are pull requests to talk about, rather than at the first launch.
            if settings.notifications { notifier?.requestAuthorization() }
            if mode == .live, snapshot.problem == nil {
                settings.pruneSeen(keeping: Set(snapshot.records.map(\.id)))
            }
        }
        recompute(announce: true)
    }

    private func recompute(announce: Bool = false) {
        let now = Date()
        let seen = settings.seen
        let options = settings.classifierOptions
        let resolved = state.records.compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), now: now, options: options)
        }
        let sorted = PROrdering.sorted(resolved)
        self.now = now
        if sorted != items { items = sorted }
        let newCounts = GroupCounts(sorted)
        if newCounts != counts {
            counts = newCounts
            let summary = PRGroup.allCases.filter { newCounts[$0] > 0 }.map { "\(newCounts[$0]) \($0.rawValue)" }
            Log.app.info("Pull requests: \(summary.isEmpty ? "none" : summary.joined(separator: ", "), privacy: .public)")
        }

        var newProblem = state.problem
        // The engine hasn't picked up organizations just chosen yet.
        if newProblem == .noOrganizations, !settings.organizations.isEmpty { newProblem = nil }
        if mode == .live, settings.organizations.isEmpty {
            switch discovery {
            // The panel says it's looking.
            case .running: newProblem = nil
            case .failed: newProblem = discoveryProblem ?? state.problem
            case .idle: newProblem = settings.hasDiscovered ? state.problem : nil
            }
        }
        if newProblem != problem {
            problem = newProblem
            if let newProblem { Log.app.error("\(newProblem.message, privacy: .public)") }
        }

        let newBrief = Brief.items(from: sorted, reader: state.userName)
        if newBrief != brief { brief = newBrief }
        if settings.summaries {
            for item in newBrief {
                if let request = briefRequest(item) { summarizer.request(request) }
            }
        }

        // Only new data is announced: when what you've seen, a setting or the time changes, the list it's
        // compared with next moves along without announcing anything.
        if state.hasLoaded {
            if announce, !state.isRefreshing, let announced, settings.notifications, let notifier {
                let firstLoaded = state.firstLoaded
                let startedAt = self.startedAt
                let notes = NotificationPlanner.plan(previous: announced, current: sorted) { item in
                    // An organization added later starts from when it was first read.
                    max(startedAt, firstLoaded[item.key.organization] ?? .distantFuture)
                }
                .filter { delivered.insert($0.id).inserted }
                if !notes.isEmpty {
                    Log.app.info("Announcing \(notes.count) update(s)")
                    notifier.post(notes)
                }
            }
            announced = sorted
        }
    }

    // MARK: Summaries

    /// Whether the brief shows: summaries on, Apple Intelligence available, and something to say.
    var showsBrief: Bool {
        settings.summaries && summarizer.isAvailable && !brief.isEmpty
    }

    func briefText(_ item: BriefItem) -> String {
        briefRequest(item).flatMap { summarizer.text(for: $0) } ?? item.sentence
    }

    /// Whether the on-device model wrote this line (rather than the plain sentence).
    func isSummarized(_ item: BriefItem) -> Bool {
        briefRequest(item).flatMap { summarizer.text(for: $0) } != nil
    }

    func briefRequest(_ item: BriefItem) -> Summarizer.Request? {
        item.prompt.map { Summarizer.Request(prompt: $0, instructions: Brief.instructions) }
    }
}
