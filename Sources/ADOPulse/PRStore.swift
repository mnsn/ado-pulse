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
    /// Whether ADO Pulse can read Notification Center, for pull requests sent in chats; nil while that's off.
    @Published private(set) var chatAccess: AccessStatus?
    /// Why Notification Center couldn't be read, though ADO Pulse has access.
    @Published private(set) var chatProblem: String?
    /// Opens the window that explains Full Disk Access.
    var showChatAccessSetup: (() -> Void)?

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
    private var chatMonitor: ChatLinkMonitor?
    /// Set when you turn the feature on, so the setup window opens if access is missing.
    private var setUpChatAccessWhenNeeded = false
    /// What the open panel has shown in Answered, and when you answered each: seen once the panel closes.
    private var answeredInPanel: [PRKey: Date] = [:]
    private var isPanelOpen = false
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
            updateChatMonitor()
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

        settings.$chatLinksEnabled.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    self?.setUpChatAccessWhenNeeded = enabled
                    self?.updateChatMonitor()
                }
            }
            .store(in: &cancellables)

        settings.$chatLinks.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateLinkedPullRequests()
                    self?.recompute()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Pull requests sent in chats

    /// Reads Notification Center only while the feature is on; turning it off forgets what was found.
    private func updateChatMonitor() {
        guard mode == .live else { return }
        if settings.chatLinksEnabled {
            guard chatMonitor == nil else { return }
            let monitor = ChatLinkMonitor { [weak self] snapshot in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.receiveChats(snapshot) }
                }
            }
            chatMonitor = monitor
            monitor.start()
            Log.app.info("Looking for pull requests sent in chats")
        } else {
            if let chatMonitor {
                chatMonitor.stop()
                Log.app.info("Stopped looking for pull requests sent in chats")
            }
            chatMonitor = nil
            chatAccess = nil
            chatProblem = nil
            settings.forgetChatLinks()
        }
        updateLinkedPullRequests()
        recompute()
    }

    private func receiveChats(_ snapshot: ChatLinkMonitor.Snapshot) {
        if chatAccess != snapshot.access {
            chatAccess = snapshot.access
            Log.app.info("Notification Center access: \(snapshot.access.rawValue, privacy: .public)")
            if snapshot.access == .granted { settings.chatAccessWasGranted = true }
        }
        if chatProblem != snapshot.problem {
            chatProblem = snapshot.problem
            if let problem = snapshot.problem { Log.app.error("\(problem, privacy: .public)") }
        }
        if snapshot.access == .granted {
            if settings.addChatLinks(snapshot.links) {
                Log.app.info("Pull request links in chats: \(self.settings.chatLinks.links.count)")
            }
        } else if setUpChatAccessWhenNeeded {
            showChatAccessSetup?()
        }
        setUpChatAccessWhenNeeded = false
    }

    private func updateLinkedPullRequests() {
        let keys = settings.chatLinksEnabled ? settings.chatLinks.keys : []
        if let engine { Task { await engine.setLinkedPullRequests(keys) } }
    }

    /// While the setup window is open, checks for access every two seconds.
    func setWaitingForChatAccess(_ waiting: Bool) {
        chatMonitor?.setWaitingForAccess(waiting)
        if waiting { chatMonitor?.refresh() }
    }

    /// Opens the message that sent the pull request: the exact message in Teams, or the app otherwise.
    func openSource(_ item: PRSnapshot) {
        guard let source = item.chatSource else { return }
        if let url = source.messageURL, NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.app) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
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
        chatMonitor?.refresh()
        guard Date().timeIntervalSince(refreshedAt ?? .distantPast) > 30 else { return }
        refresh()
    }

    /// The panel opened: what it shows in Answered counts as seen once it closes.
    func panelDidOpen() {
        isPanelOpen = true
        noteAnsweredInPanel()
    }

    /// The panel closed: what it showed in Answered goes back to its usual group. Each is seen up to when you
    /// answered it, not up to now, so whatever came after still counts as new.
    func panelDidClose() {
        isPanelOpen = false
        let shown = answeredInPanel
        answeredInPanel = [:]
        settings.markSeen(shown.map { (key: $0.key, date: $0.value) })
    }

    private func noteAnsweredInPanel() {
        for item in items where item.group == .answered {
            answeredInPanel[item.key] = max(answeredInPanel[item.key] ?? .distantPast, item.since ?? now)
        }
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
        let links = settings.chatLinksEnabled ? settings.chatLinks : ChatLinkState()
        let resolved = state.records.compactMap { record -> PRSnapshot? in
            var record = record
            let found = links.links(for: record.id).filter { link in !record.chatLinks.contains { $0.id == link.id } }
            record.chatLinks += found
            return PRClassifier.snapshot(for: record, seenCutoff: seen.cutoff(for: record.id), now: now, options: options)
        }
        let sorted = PROrdering.sorted(resolved)
        self.now = now
        if sorted != items { items = sorted }
        if isPanelOpen { noteAnsweredInPanel() }
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
