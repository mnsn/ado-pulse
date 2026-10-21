import ADOPulseCore
import Foundation

/// Command-line modes, mainly for checking what the panel would show.
enum CLI {
    static let usage = """
        ADO Pulse: your Azure DevOps pull requests at a glance.

        Usage: ADOPulse [options]
          (no option)      Run the menu-bar app and desktop widget
          --dump           Print every pull request and its status
          --json           Print the same as JSON, with counts
          --watch          Print changes as they happen (Ctrl-C to stop)
          --orgs           List your organizations, and the ones where you have pull requests
          --chats          List the pull request links in Notification Center's notifications (needs Full Disk Access)
          --render <dir>   Draw the menu bar with the panel open, and each widget size, to PNGs (light and dark)
          --demo           Use made-up pull requests, with any of the above or the app
          --org <name>     Read this organization instead of the app's choice (repeatable)
          --help           Show this help

        ADO Pulse signs in with the Azure CLI (az login) and only reads: every request is a GET.
        """

    struct Options {
        var demo = false
        var organizations: [String] = []

        init(_ arguments: [String]) {
            demo = arguments.contains("--demo")
            var index = 0
            while index < arguments.count {
                if arguments[index] == "--org", index + 1 < arguments.count {
                    organizations.append(arguments[index + 1])
                    index += 1
                }
                index += 1
            }
        }
    }

    /// Returns an exit code for command-line modes, or nil to launch the app.
    static func run(_ arguments: [String]) -> Int32? {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        let options = Options(arguments)
        if arguments.contains("--json") {
            return printJSON(load(options))
        }
        if arguments.contains("--dump") {
            let loaded = load(options)
            printTable(loaded)
            return loaded.items.isEmpty && loaded.problem != nil ? 1 : 0
        }
        if arguments.contains("--orgs") {
            return listOrganizations()
        }
        if arguments.contains("--chats") {
            return listChatLinks()
        }
        if arguments.contains("--watch") {
            watch(options)
        }
        return nil
    }

    // MARK: Loading

    struct Loaded {
        var organizations: [String]
        var items: [PRSnapshot]
        var problem: String?
    }

    /// The app's own settings (read-only), so the output matches the panel.
    private static var appDefaults: UserDefaults? { AppSettings.appDefaults }

    private static func classifierOptions() -> ClassifierOptions {
        let defaults = appDefaults
        let idleDays = defaults?.object(forKey: SettingsKey.idleDays) as? Int ?? 14
        let keepDoneHours = defaults?.object(forKey: SettingsKey.keepDoneHours) as? Int ?? 24
        return ClassifierOptions(
            inactiveAfter: idleDays > 0 ? TimeInterval(idleDays) * 86_400 : nil,
            keepDoneFor: TimeInterval(keepDoneHours > 0 ? keepDoneHours : 24) * 3_600
        )
    }

    /// The links the app found, when pull requests sent in chats are on.
    private static func chatLinks() -> ChatLinkState {
        guard appDefaults?.bool(forKey: SettingsKey.chatLinksEnabled) == true else { return ChatLinkState() }
        return appDefaults?.data(forKey: SettingsKey.chatLinks).flatMap { try? JSONDecoder().decode(ChatLinkState.self, from: $0) }
            ?? ChatLinkState()
    }

    private static func seenState() -> SeenState {
        appDefaults?.data(forKey: SettingsKey.seen).flatMap { try? JSONDecoder().decode(SeenState.self, from: $0) }
            ?? SeenState.firstRun()
    }

    static func resolve(
        _ snapshot: PulseSnapshot, seen: SeenState, options: ClassifierOptions, links: ChatLinkState = ChatLinkState(), now: Date = Date()
    ) -> [PRSnapshot] {
        PROrdering.sorted(snapshot.records.compactMap { record in
            var record = record
            record.chatLinks += links.links(for: record.id).filter { link in !record.chatLinks.contains { $0.id == link.id } }
            return PRClassifier.snapshot(for: record, seenCutoff: seen.cutoff(for: record.id), now: now, options: options)
        })
    }

    private static func load(_ options: Options) -> Loaded {
        if options.demo {
            let now = Date()
            let snapshot = DemoData.snapshot(now: now)
            return Loaded(organizations: snapshot.organizations,
                          items: resolve(snapshot, seen: DemoData.seenState(now: now), options: ClassifierOptions(), now: now))
        }
        let client = ADOClient(tokens: AzureCLITokenProvider())
        var organizations = options.organizations
        if organizations.isEmpty {
            organizations = appDefaults?.stringArray(forKey: SettingsKey.organizations) ?? []
        }
        if organizations.isEmpty {
            FileHandle.standardError.write(Data("No organizations chosen in the app yet: looking for yours…\n".utf8))
            organizations = wait {
                guard let all = try? await OrganizationDiscovery.memberships(client: client) else { return [] }
                return await OrganizationDiscovery.withPullRequests(all, client: client)
            }
        }
        let configuration = PulseEngine.Configuration(organizations: organizations, keepDoneFor: classifierOptions().keepDoneFor)
        let links = chatLinks()
        let snapshot = wait { await PulseEngine.loadOnce(client: client, configuration: configuration, linked: links.keys) }
        return Loaded(
            organizations: organizations, items: resolve(snapshot, seen: seenState(), options: classifierOptions(), links: links),
            problem: snapshot.problem?.message
        )
    }

    // MARK: Output

    private static func printJSON(_ loaded: Loaded) -> Int32 {
        struct Output: Encodable {
            var organizations: [String]
            var counts: GroupCounts
            var items: [PRSnapshot]
            var problem: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let output = Output(organizations: loaded.organizations, counts: GroupCounts(loaded.items), items: loaded.items, problem: loaded.problem)
        guard let data = try? encoder.encode(output) else { return 1 }
        FileHandle.standardOutput.write(data)
        print()
        return 0
    }

    private static func printTable(_ loaded: Loaded) {
        if let problem = loaded.problem { print("! \(problem)") }
        let now = Date()
        let counts = GroupCounts(loaded.items)
        print(PRGroup.allCases.map { "\($0.countLabel) \(counts[$0])" }.joined(separator: " · "))
        print(row("GROUP", "STATUS", "SINCE", "PULL REQUEST", "DETAIL"))
        for item in loaded.items {
            print(row(
                item.group.rawValue, item.headline, Elapsed.short(since: item.since, now: now),
                "!\(item.key.number) \(item.title) [\(item.repository)]", item.detail ?? ""
            ))
        }
    }

    private static func row(_ group: String, _ status: String, _ since: String, _ title: String, _ detail: String) -> String {
        [pad(group, 9), pad(status, 30), pad(since, 7), pad(title, 50), String(detail.prefix(70))].joined(separator: " ")
    }

    static func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private static func listOrganizations() -> Int32 {
        let client = ADOClient(tokens: AzureCLITokenProvider())
        let result: Result<([String], [String]), ADOError> = wait {
            do {
                let all = try await OrganizationDiscovery.memberships(client: client)
                return .success((all, await OrganizationDiscovery.withPullRequests(all, client: client)))
            } catch {
                return .failure((error as? ADOError) ?? .network(error.localizedDescription))
            }
        }
        switch result {
        case .success(let (all, withPullRequests)):
            let watched = Set(appDefaults?.stringArray(forKey: SettingsKey.organizations) ?? [])
            print("\(all.count) organizations; \(withPullRequests.count) with pull requests (*); watched by the app (+)")
            for name in all {
                print("\(withPullRequests.contains(name) ? "*" : " ")\(watched.contains(name) ? "+" : " ") \(name)")
            }
            return 0
        case .failure(let error):
            FileHandle.standardError.write(Data("\(error.description)\n".utf8))
            return 1
        }
    }

    /// What `--chats` finds: every pull request link in the stored notifications, with who sent it where.
    private static func listChatLinks() -> Int32 {
        let database = NotificationCenterDatabase.defaultURL()
        switch DatabaseAccess.check(database) {
        case .denied:
            FileHandle.standardError.write(Data("""
                Can't read Notification Center's database: give Terminal Full Disk Access in System Settings › \
                Privacy & Security › Full Disk Access, then quit and reopen Terminal and run this again.

                """.utf8))
            return 1
        case .missing:
            FileHandle.standardError.write(Data("There's no Notification Center database at \(database.path).\n".utf8))
            return 1
        case .granted:
            break
        }
        let records: [StoredRecord]
        do {
            records = try NotificationCenterDatabase.load(at: database)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
        let links = ChatLinkScanner.scan(records)
        let apps = Set(records.map(\.bundleIdentifier)).count
        print("\(records.count) notifications from \(apps) apps; \(links.count) links to pull requests")
        let now = Date()
        for link in links.sorted(by: { $0.sentAt > $1.sentAt }) {
            print([pad(Elapsed.short(since: link.sentAt, now: now), 7), pad(link.appName, 10), pad(link.sender ?? "", 28),
                   "\(link.key)  \(link.messageURL == nil ? "" : "(message link)")"].joined(separator: " "))
        }
        return 0
    }

    private static func watch(_ options: Options) -> Never {
        let organizations = options.organizations.isEmpty
            ? appDefaults?.stringArray(forKey: SettingsKey.organizations) ?? []
            : options.organizations
        let links = chatLinks()
        let printer = WatchPrinter(seen: seenState(), options: classifierOptions(), links: links)
        let queue = DispatchQueue(label: "ADOPulse.watch")
        let engine = PulseEngine(
            client: ADOClient(tokens: AzureCLITokenProvider()), configuration: PulseEngine.Configuration(organizations: organizations)
        ) { snapshot in queue.async { printer.print(snapshot) } }
        setvbuf(stdout, nil, _IOLBF, 0)
        print("Watching \(organizations.joined(separator: ", ")), refreshing every minute — Ctrl-C to stop")
        Task {
            await engine.setLinkedPullRequests(links.keys)
            await engine.start()
        }
        withExtendedLifetime(engine) { dispatchMain() }
    }

    /// Runs async work from the synchronous command line.
    static func wait<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}

/// Prints only the pull requests whose status changed. Confined to the watch queue.
private final class WatchPrinter: @unchecked Sendable {
    private let seen: SeenState
    private let options: ClassifierOptions
    private let links: ChatLinkState
    private var problem: String?
    private var previous: [String: PRSnapshot] = [:]
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(seen: SeenState, options: ClassifierOptions, links: ChatLinkState) {
        self.seen = seen
        self.options = options
        self.links = links
    }

    func print(_ snapshot: PulseSnapshot) {
        guard !snapshot.isRefreshing else { return }
        let now = Date()
        let message = snapshot.problem?.message
        if message != problem {
            problem = message
            if let message { Swift.print("\(formatter.string(from: now))  ! \(message)") }
        }
        for item in CLI.resolve(snapshot, seen: seen, options: options, links: links, now: now) {
            let old = previous[item.id]
            previous[item.id] = item
            guard old == nil || old?.group != item.group || old?.headline != item.headline || old?.detail != item.detail else { continue }
            if old == nil, item.group == .idle { continue }
            let detail = item.detail.map { " — \($0.prefix(90))" } ?? ""
            Swift.print("\(formatter.string(from: now))  \(item.group.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) "
                + "\(item.headline): !\(item.key.number) \(item.title)\(detail)")
        }
    }
}
