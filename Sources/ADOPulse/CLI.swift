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
          --chats          List the pull request links in Notification Center's notifications (run it from Terminal,
                           which needs Full Disk Access)
          --render <dir>   Draw the menu bar with the panel open, and each widget size, to PNGs (light and dark)
          --demo           Use made-up pull requests, with any of the above or the app
          --org <name>     Read this organization instead of the app's choice (repeatable)
          --help           Show this help

        ADO Pulse signs in with the Azure CLI (az login) and only reads: every request is a GET.
        The modes above run only from a shell, such as Terminal's, with its permissions: started as an
        app (by open, say), ADO Pulse has its own Full Disk Access, so it refuses them.
        """

    /// The modes that run instead of the app, and print or save what they read.
    static let modes = ["--dump", "--json", "--watch", "--orgs", "--chats", "--render"]

    /// Why the command-line modes and `--render` can't run, or nil when they can. They print or save what they read,
    /// so they run only with the permissions of the app that started ADO Pulse, such as Terminal. Started as an app
    /// (by `open`, say), or by a program that disclaimed it, ADO Pulse has its own Full Disk Access, and whoever
    /// started it chose the arguments and could read the output, even with `--demo`.
    static func refusal(_ arguments: [String], attribution: Attribution) -> String? {
        guard attribution == .itself, arguments.contains(where: modes.contains) else { return nil }
        return """
            ADO Pulse's command-line modes and --render run only from a shell, such as Terminal's, with its \
            permissions. Started as an app (by open, say), ADO Pulse has its own Full Disk Access, so they don't \
            run. Run \(Bundle.main.executablePath ?? "ADOPulse") from Terminal instead.
            """
    }

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

    /// Returns an exit code for command-line modes, or nil to launch the app (or, for `--render`, to draw it).
    static func run(_ arguments: [String], attribution: Attribution = .current) -> Int32? {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        if let refusal = refusal(arguments, attribution: attribution) {
            FileHandle.standardError.write(Data("\(refusal)\n".utf8))
            return 1
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
        // The demo never uses the Azure CLI, your settings or Azure DevOps.
        if arguments.contains("--orgs") {
            return options.demo ? listDemoOrganizations() : listOrganizations()
        }
        if arguments.contains("--chats") {
            return options.demo ? listDemoChatLinks() : listChatLinks()
        }
        if arguments.contains("--watch") {
            if options.demo { return watchDemo() }
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

    /// What the app's accounts have seen.
    private static func seenBook() -> SeenBook {
        let decoder = JSONDecoder()
        return SeenBook(
            current: appDefaults?.data(forKey: SettingsKey.seen).flatMap { try? decoder.decode(SeenState.self, from: $0) }
                ?? SeenState.firstRun(),
            others: appDefaults?.data(forKey: SettingsKey.otherSeen).flatMap { try? decoder.decode([String: SeenState].self, from: $0) }
                ?? [:]
        )
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
            let found: Result<OrganizationDiscovery.Found, ADOError> = wait {
                do {
                    return .success(try await OrganizationDiscovery.discover(client: client))
                } catch {
                    return .failure((error as? ADOError) ?? .network(error.localizedDescription))
                }
            }
            switch found {
            case .success(let found): organizations = found.withPullRequests
            case .failure(let error):
                return Loaded(organizations: [], items: [], problem: "Couldn't find your organizations: \(error.description)")
            }
        }
        let configuration = PulseEngine.Configuration(organizations: organizations, keepDoneFor: classifierOptions().keepDoneFor)
        let links = chatLinks()
        let snapshot = wait { await PulseEngine.loadOnce(client: client, configuration: configuration, linked: links.keys) }
        return Loaded(
            organizations: organizations, items: resolve(
                snapshot, seen: seenBook().state(for: snapshot.account), options: classifierOptions(), links: links
            ),
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
        let result: Result<([String], OrganizationDiscovery.Probe), ADOError> = wait {
            do {
                let all = try await OrganizationDiscovery.memberships(client: client)
                return .success((all, await OrganizationDiscovery.probe(all, client: client)))
            } catch {
                return .failure((error as? ADOError) ?? .network(error.localizedDescription))
            }
        }
        switch result {
        case .success(let (all, probe)):
            let watched = Set(appDefaults?.stringArray(forKey: SettingsKey.organizations) ?? [])
            print("\(all.count) organizations; \(probe.withPullRequests.count) with pull requests (*); watched by the app (+)")
            for name in all {
                let mark = probe.withPullRequests.contains(name) ? "*" : probe.failures[name] != nil ? "?" : " "
                print("\(mark)\(watched.contains(name) ? "+" : " ") \(name)")
            }
            if let failure = probe.failures.min(by: { $0.key < $1.key }) {
                FileHandle.standardError.write(Data("Couldn't check \(probe.failures.count) (?), such as \(failure.key): \(failure.value.description)\n".utf8))
                return 1
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
        printChatLinks(links)
        return 0
    }

    /// The made-up links in the demo, without reading Notification Center.
    private static func listDemoChatLinks() -> Int32 {
        let links = DemoData.records(now: Date()).flatMap(\.chatLinks)
        print("Made-up notifications; \(links.count) links to pull requests")
        printChatLinks(links)
        return 0
    }

    private static func printChatLinks(_ links: [ChatLink]) {
        let now = Date()
        for link in links.sorted(by: { $0.sentAt > $1.sentAt }) {
            print([pad(Elapsed.short(since: link.sentAt, now: now), 7), pad(link.appName, 10), pad(link.sender ?? "", 28),
                   "\(link.key)  \(link.messageURL == nil ? "" : "(message link)")"].joined(separator: " "))
        }
    }

    private static func listDemoOrganizations() -> Int32 {
        print("1 organization; 1 with pull requests (*); watched by the app (+)")
        print("*+ \(DemoData.organization)")
        return 0
    }

    /// The made-up pull requests, then the demo's one change a second later, as `--watch` prints them.
    private static func watchDemo() -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("Watching \(DemoData.organization), made-up pull requests")
        let now = Date()
        let printer = WatchPrinter(seen: SeenBook(current: DemoData.seenState(now: now)), options: ClassifierOptions(), links: ChatLinkState())
        let snapshot = DemoData.snapshot(now: now)
        printer.print(snapshot)
        Thread.sleep(forTimeInterval: 1)
        printer.print(DemoData.update(snapshot, at: Date()))
        print("That's all the demo does.")
        return 0
    }

    private static func watch(_ options: Options) -> Never {
        let organizations = options.organizations.isEmpty
            ? appDefaults?.stringArray(forKey: SettingsKey.organizations) ?? []
            : options.organizations
        let links = chatLinks()
        let printer = WatchPrinter(seen: seenBook(), options: classifierOptions(), links: links)
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
    private var seen: SeenBook
    private let options: ClassifierOptions
    private let links: ChatLinkState
    private var problem: String?
    private var previous: [String: PRSnapshot] = [:]
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(seen: SeenBook, options: ClassifierOptions, links: ChatLinkState) {
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
        // Once, so an account's first run starts when it was first seen.
        if let account = snapshot.account { seen.signIn(account, now: now) }
        for item in CLI.resolve(snapshot, seen: seen.current, options: options, links: links, now: now) {
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
