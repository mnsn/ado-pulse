import Foundation
import Synchronization
import Testing
@testable import ADOPulseCore

@Suite struct PullRequestLinkTests {
    @Test(arguments: [
        ("See https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/7 please", "contoso", "Shop", "shop-web", 7),
        ("dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/7?_a=files&path=/src/a.cs", "contoso", "Shop", "shop-web", 7),
        ("https://DEV.AZURE.COM/Contoso/Shop/_git/shop-web/PullRequest/7#comment", "Contoso", "Shop", "shop-web", 7),
        ("https://contoso.visualstudio.com/Shop/_git/shop-web/pullrequest/12", "contoso", "Shop", "shop-web", 12),
        ("https://contoso.visualstudio.com/DefaultCollection/Shop/_git/shop-web/pullrequest/12/", "contoso", "Shop", "shop-web", 12),
        ("https://dev.azure.com/contoso/My%20Shop/_git/web%20app/pullrequest/3", "contoso", "My Shop", "web app", 3),
        ("Review <https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/7>.", "contoso", "Shop", "shop-web", 7),
        ("(https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/7), thanks", "contoso", "Shop", "shop-web", 7),
    ] as [(String, String, String, String, Int)])
    func findsLinks(_ text: String, _ organization: String, _ project: String, _ repository: String, _ number: Int) {
        let links = PullRequestLink.find(in: text)
        #expect(links == [PullRequestLink(organization: organization, project: project, repository: repository, number: number)])
    }

    @Test(arguments: [
        "No link here",
        "https://dev.azure.com/contoso/Shop/_workitems/edit/7",
        "https://dev.azure.com/contoso/Shop/_build/results?buildId=7",
        "https://github.com/contoso/shop-web/pull/7",
        "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequests",
        "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/12345678901",
        "pullrequest 7",
    ])
    func ignoresOtherLinks(_ text: String) {
        #expect(PullRequestLink.find(in: text).isEmpty)
    }

    @Test func findsEachPullRequestOnce() {
        let text = """
            \(Chats.link) and again \(Chats.link)?_a=overview, plus https://contoso.visualstudio.com/Shop/_git/api/pullrequest/9
            """
        #expect(PullRequestLink.find(in: text).map(\.number) == [7, 9])
        #expect(PullRequestLink.find(in: text).first?.url.absoluteString == Chats.link)
    }
}

@Suite struct ChatLinkScannerTests {
    private func links(_ data: Data, app: String, delivered: Date? = t(0)) throws -> [ChatLink] {
        ChatLinkScanner.links(in: try #require(NotificationRecord.raw(data, app: app, delivered: delivered)))
    }

    @Test func teamsOneOnOneMessages() throws {
        let data = NotificationRecord.teamsMessage(Chats.dana, title: "Dana Whitfield", body: "Can you look? \(Chats.link)", at: t(-60))
        let found = try links(data, app: Chats.teams, delivered: t(-60))
        #expect(found.count == 1)
        let link = try #require(found.first)
        #expect(link.key == PRKey("contoso", 7))
        #expect(link.sender == "Dana Whitfield")
        #expect(link.app == Chats.teams)
        #expect(link.appName == "Teams")
        #expect(link.sentAt == t(-60))
        #expect(link.conversation == Chats.dana)
        #expect(link.messageID == teamsMessageID(t(-60)))
        let url = try #require(link.messageURL).absoluteString
        #expect(url.hasPrefix("msteams:/l/message/19%3A11111111-aaaa"))
        #expect(url.contains("/\(teamsMessageID(t(-60)))?context="))
    }

    @Test func teamsGroupMessagesNameTheSender() throws {
        let data = NotificationRecord.teamsMessage(Chats.launchCrew, title: "Launch crew", body: "Dana Whitfield: please review \(Chats.link)", at: t(0))
        #expect(try links(data, app: Chats.teams).first?.sender == "Dana Whitfield")
    }

    @Test func teamsReactionsAndChannelPostsDontCount() throws {
        let reaction = NotificationRecord.teamsMessage(Chats.dana, title: "Dana Whitfield", body: "Liked \(Chats.link)", at: t(0), reply: false)
        #expect(try links(reaction, app: Chats.teams).isEmpty)
        let post = NotificationRecord.teamsChannelPost(title: "Engineering", body: "New PR: \(Chats.link)", at: t(0))
        #expect(try links(post, app: Chats.teams).isEmpty)
        // Teams without user info can't be told apart, so it doesn't count either.
        let bare = NotificationRecord.data(app: Chats.teams, title: "Dana Whitfield", body: Chats.link, date: t(0))
        #expect(try links(bare, app: Chats.teams).isEmpty)
    }

    @Test func otherAppsUseTheTitleAsTheSender() throws {
        let slack = NotificationRecord.data(app: Chats.slack, title: "Dana Whitfield", body: "PTAL \(Chats.link)", date: t(0))
        let found = try links(slack, app: Chats.slack)
        #expect(found.first?.sender == "Dana Whitfield")
        #expect(found.first?.appName == "Slack")
        #expect(found.first?.messageURL == nil)

        let mail = NotificationRecord.data(app: Chats.outlook, title: "Sam Rivera", subtitle: "Review: \(Chats.link)", body: "Thanks!", date: t(0))
        #expect(try links(mail, app: Chats.outlook).first?.sender == "Sam Rivera")
        #expect(ChatApps.name(for: "com.example.messenger") == "Messenger")
    }

    @Test func azureDevOpsEmailsAndOwnNotificationsDontCount() throws {
        let email = NotificationRecord.data(app: Chats.outlook, title: "Azure DevOps", subtitle: "Pull request 7 was approved",
                                            body: Chats.link, date: t(0))
        #expect(try links(email, app: Chats.outlook).isEmpty)
        let own = NotificationRecord.data(app: ChatLinkScanner.ownBundleIdentifier, title: "Sam Rivera replied", body: Chats.link, date: t(0))
        #expect(try links(own, app: ChatLinkScanner.ownBundleIdentifier).isEmpty)
        let undated = NotificationRecord.data(app: Chats.slack, title: "Dana Whitfield", body: Chats.link, date: t(0))
        #expect(ChatLinkScanner.links(in: try #require(NotificationRecord.raw(undated, app: Chats.slack, delivered: nil)))
            .first?.sentAt == t(0))
    }

    @Test func teamsLinks() {
        #expect(TeamsLink.message(conversation: Chats.dana, messageID: "1792317600000")?.absoluteString
            == "msteams:/l/message/19%3A11111111-aaaa-4aaa-8aaa-111111111111_99999999-ffff-4fff-8fff-999999999999%40unq.gbl.spaces/1792317600000?context=%7B%22contextType%22%3A%22chat%22%7D")
        #expect(TeamsLink.message(conversation: "not a chat", messageID: "1") == nil)
        #expect(TeamsLink.message(conversation: Chats.dana, messageID: "12a") == nil)
        #expect(TeamsLink.chat(conversation: Chats.launchCrew)?.absoluteString.hasPrefix("msteams:/l/chat/19%3A0123") == true)
    }
}

@Suite struct NotificationCenterTests {
    @Test func readsEveryAppsNotificationsAndFindsTheLinks() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("db2/db")
            let db = try TestNotificationDatabase(at: url)
            defer { db.close() }
            try db.add(NotificationRecord.teamsMessage(Chats.dana, title: "Dana Whitfield", body: "PTAL \(Chats.link)", at: t(-120)),
                       app: Chats.teams, delivered: t(-120))
            try db.add(NotificationRecord.teamsMessage(Chats.dana, title: "Dana Whitfield", body: "Lunch?", at: t(-60)),
                       app: Chats.teams, delivered: t(-60))
            try db.add(NotificationRecord.data(app: Chats.slack, title: "Sam Rivera",
                                               body: "https://contoso.visualstudio.com/Shop/_git/api/pullrequest/9", date: t(-30)),
                       app: Chats.slack, delivered: t(-30))
            try db.add(Data("not a plist".utf8), app: "com.apple.mail", delivered: t(0))

            #expect(DatabaseAccess.check(url) == .granted)
            let records = try NotificationCenterDatabase.load(at: url)
            #expect(records.count == 4)
            #expect(Set(records.map(\.bundleIdentifier)) == [Chats.teams, Chats.slack, "com.apple.mail"])
            let links = ChatLinkScanner.scan(records)
            #expect(links.map(\.key) == [PRKey("contoso", 7), PRKey("contoso", 9)])
            #expect(links.map(\.sender) == ["Dana Whitfield", "Sam Rivera"])

            let snapshot = ChatLinkMonitor.scanOnce(database: url)
            #expect(snapshot.access == .granted)
            #expect(snapshot.links.count == 2)
            #expect(snapshot.problem == nil)
        }
    }

    @Test func reportsAMissingDatabaseOrAChangedLayout() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("db2/db")
            #expect(DatabaseAccess.check(missing) == .missing)
            #expect(ChatLinkMonitor.scanOnce(database: missing).access == .missing)

            let changed = directory.appendingPathComponent("other/db")
            let db = try TestNotificationDatabase(at: changed, schema: "CREATE TABLE something (id INTEGER);")
            defer { db.close() }
            #expect(throws: NotificationDatabaseError.layoutChanged(missing: ["app.app_id", "app.identifier", "record.app_id", "record.data"])) {
                try NotificationCenterDatabase.load(at: changed)
            }
            #expect(ChatLinkMonitor.scanOnce(database: changed).problem?.contains("has changed") == true)
        }
    }

    @Test func pointsAtAnotherDatabaseForTests() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(NotificationCenterDatabase.defaultURL(environment: [:], home: home).path
            == "/Users/someone/Library/Group Containers/group.com.apple.usernoted/db2/db")
        #expect(NotificationCenterDatabase.defaultURL(environment: ["ADO_PULSE_NOTIFICATIONS_DB": "/tmp/fixture/db"], home: home).path
            == "/tmp/fixture/db")
    }

    @Test(.timeLimit(.minutes(1)))
    func nothingArrivesOnceStopped() async throws {
        let link = ChatLink(link: PullRequestLink(organization: "contoso", project: "Shop", repository: "web", number: 7),
                            app: Chats.teams, sender: "Dana Whitfield", sentAt: t(0), notificationKey: "n1")
        func run(stopping: Bool) async throws -> Int {
            // A read that's under way, held until the test lets it finish.
            let reading = DispatchSemaphore(value: 0)
            let finish = DispatchSemaphore(value: 0)
            let delivery = DispatchQueue(label: "test.delivery")
            let delivered = Locked(0)
            let monitor = ChatLinkMonitor(database: URL(fileURLWithPath: "/nonexistent/db"), deliverOn: delivery, scan: { _ in
                reading.signal()
                finish.wait()
                return ChatLinkMonitor.Snapshot(access: .granted, links: [link])
            }) { _ in delivered.increment() }
            monitor.start()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { reading.wait(); continuation.resume() }
            }
            // Turned off where it delivers, as the app does on the main thread, while the read is under way.
            if stopping { delivery.sync { monitor.stop() } }
            finish.signal()
            try await Task.sleep(for: .milliseconds(200))
            delivery.sync {}
            if !stopping { monitor.stop() }
            return delivered.value
        }
        #expect(try await run(stopping: false) == 1)
        #expect(try await run(stopping: true) == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func picksUpNewNotificationsAsTheyArrive() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db2/db")
        let db = try TestNotificationDatabase(at: url)
        defer { db.close() }
        try db.add(NotificationRecord.data(app: Chats.slack, title: "Sam Rivera", body: "Hi", date: t(0)), app: Chats.slack, delivered: t(0))

        let latest = Mutex<ChatLinkMonitor.Snapshot?>(nil)
        let monitor = ChatLinkMonitor(database: url, debounce: 0.05, deliverOn: DispatchQueue(label: "test")) { snapshot in
            latest.withLock { $0 = snapshot }
        }
        monitor.start()
        defer { monitor.stop() }
        try await waitFor("the first read") { latest.withLock { $0?.access == .granted } }
        #expect(latest.withLock { $0?.links.isEmpty } == true)

        // Notification Center writes to its write-ahead log; the monitor sees it without waiting a minute.
        try db.add(NotificationRecord.teamsMessage(Chats.dana, title: "Dana Whitfield", body: Chats.link, at: t(10)),
                   app: Chats.teams, delivered: t(10))
        try await waitFor("the new link") { latest.withLock { $0?.links.count == 1 } }
    }
}

private func waitFor(_ what: String, timeout: Duration = .seconds(10), until condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw TestError("Timed out waiting for \(what)")
}

@Suite struct ChatLinkStateTests {
    private func link(_ number: Int, key: String = "n1", at date: Date = t(0), organization: String = "contoso") -> ChatLink {
        ChatLink(link: PullRequestLink(organization: organization, project: "Shop", repository: "web", number: number),
                 app: Chats.teams, sender: "Dana Whitfield", sentAt: date, notificationKey: key)
    }

    @Test func keepsEachLinkOnceAndForgetsOldOnes() {
        var state = ChatLinkState()
        let added = state.merge([link(7), link(9, key: "n2", at: t(-100))])
        let addedAgain = state.merge([link(7)])
        #expect(added && !addedAgain)
        #expect(state.links.map(\.link.number) == [9, 7])
        #expect(state.keys == [PRKey("contoso", 7), PRKey("contoso", 9)])
        #expect(state.links(for: PRKey("contoso", 7)).count == 1)
        let prunedEarly = state.prune(now: t(ChatLinkState.keepFor - 101))
        let pruned = state.prune(now: t(ChatLinkState.keepFor + 1))
        #expect(!prunedEarly && pruned)
        #expect(state.links.isEmpty)

        let data = try? JSONEncoder().encode(ChatLinkState(links: [link(7)]))
        #expect(data.flatMap { try? JSONDecoder().decode(ChatLinkState.self, from: $0) } == ChatLinkState(links: [link(7)]))
    }

    @Test func appsAndNewerMessagesAreTold() {
        var state = ChatLinkState()
        state.merge([link(7, key: "chat-1", at: t(0))])
        // Slack happens to use the same identifier for its notification about the same pull request.
        var slack = link(7, key: "chat-1", at: t(60))
        slack.app = Chats.slack
        let addedSlack = state.merge([slack])
        #expect(addedSlack)
        #expect(state.links.count == 2)

        // Teams replaces its notification with a newer message: the link is the newer one.
        var newer = link(7, key: "chat-1", at: t(120))
        newer.messageID = "1700000120000"
        let tookNewer = state.merge([newer])
        #expect(tookNewer)
        #expect(state.links.count == 2)
        #expect(state.links.first { $0.app == Chats.teams }?.sentAt == t(120))
        // The older one, read again, changes nothing.
        let tookOlder = state.merge([link(7, key: "chat-1", at: t(0))])
        #expect(!tookOlder)
        #expect(state.links.first { $0.app == Chats.teams }?.messageID == "1700000120000")
    }

    @Test func usesTheWatchedOrganizationsSpelling() {
        let canonical = ChatLinkState.canonical([link(7, organization: "CONTOSO"), link(8, organization: "fabrikam")], organizations: ["Contoso"])
        #expect(canonical.map(\.link.organization) == ["Contoso", "fabrikam"])
    }
}

@Suite struct ChatLinkClassifierTests {
    private let me = People.me
    private let cutoff = t(-3 * day)

    private func sent(_ pr: PullRequest, at date: Date = t(-10 * minute)) -> ChatLink {
        ChatLink(link: PullRequestLink(organization: pr.key.organization, project: pr.projectName, repository: pr.repositoryName,
                                       number: pr.key.number),
                 app: Chats.teams, sender: "Dana Whitfield", sentAt: date, notificationKey: "n1",
                 conversation: Chats.dana, messageID: teamsMessageID(date))
    }

    private func classify(_ pr: PullRequest, role: PRRole, details: PRDetails?, links: [ChatLink], cutoff: Date? = nil,
                          now: Date = t(0)) -> PRSnapshot? {
        PRClassifier.snapshot(
            for: PRRecord(pullRequest: pr, role: role, details: details, me: me.id, chatLinks: links),
            seenCutoff: cutoff ?? self.cutoff, now: now
        )
    }

    @Test func aPullRequestSentToYouNeedsYou() throws {
        let pr = makePR(author: People.alex)
        let snapshot = try #require(classify(pr, role: .linked, details: makeDetails(for: pr, lastActivity: t(-hour)), links: [sent(pr)]))
        #expect(snapshot.group == .needsYou)
        #expect(snapshot.reason == .sentInChat)
        #expect(snapshot.headline == "Dana Whitfield sent this in Teams")
        #expect(snapshot.detail == "By Alex Kim")
        #expect(snapshot.since == t(-10 * minute))
        #expect(snapshot.url == pr.webURL)
        let source = try #require(snapshot.chatSource)
        #expect(source.appName == "Teams")
        #expect(source.messageURL?.scheme == "msteams")
    }

    @Test func itStopsNeedingYouOnceYouActOnIt() throws {
        let pr = makePR(author: People.alex)
        let link = sent(pr)
        // Opened from ADO Pulse after the message.
        #expect(classify(pr, role: .linked, details: makeDetails(for: pr), links: [link], cutoff: t(-minute)) == nil)
        // Commented after it: it's answered until you've seen that, and then it isn't listed.
        let answered = ReviewThread(id: 3, comments: [comment(1, me, "Looks good", at: t(-5 * minute))])
        #expect(classify(pr, role: .linked, details: makeDetails(for: pr, threads: [answered]), links: [link])?.group == .answered)
        #expect(classify(pr, role: .linked, details: makeDetails(for: pr, threads: [answered]), links: [link], cutoff: t(-5 * minute)) == nil)
        // Voted after it.
        let vote = Activity(threadId: 4, kind: .vote, at: t(-minute), actor: me, vote: .approved)
        #expect(classify(pr, role: .linked, details: makeDetails(for: pr, activity: [vote]), links: [link])?.group == .answered)
        #expect(classify(pr, role: .linked, details: makeDetails(for: pr, activity: [vote]), links: [link], cutoff: t(-minute)) == nil)
        // A week went by.
        #expect(classify(pr, role: .linked, details: makeDetails(for: pr), links: [sent(pr, at: t(-8 * day))]) == nil)
        // An earlier comment doesn't count.
        let earlier = ReviewThread(id: 3, comments: [comment(1, me, "Hmm", at: t(-hour))])
        #expect(classify(pr, role: .linked, details: makeDetails(for: pr, threads: [earlier]), links: [link])?.group == .needsYou)
    }

    @Test func onAPullRequestYouReviewItComesFirst() throws {
        let pr = makePR(author: People.alex, reviewers: [Reviewer(person: me, vote: .none)])
        let added = Activity(threadId: 9, kind: .reviewersChanged, at: t(-hour), actor: People.alex, added: [me.id])
        let snapshot = try #require(classify(pr, role: .reviewer, details: makeDetails(for: pr, activity: [added]), links: [sent(pr)]))
        #expect(snapshot.reason == .sentInChat)
        #expect(Set(snapshot.pendingEvents.map(\.kind)) == [.sentInChat, .reviewRequest])
        // Once seen, it's back to an ordinary review request.
        #expect(classify(pr, role: .reviewer, details: makeDetails(for: pr, activity: [added]), links: [sent(pr)], cutoff: t(0))?.group
            == .toReview)
    }

    @Test func onYourOwnPullRequestAPushAnswersIt() throws {
        let pr = makePR()
        let checks = [Check(name: "CI", kind: .build, state: .running)]
        let snapshot = try #require(classify(pr, role: .author, details: makeDetails(for: pr, checks: checks), links: [sent(pr)]))
        #expect(snapshot.reason == .sentInChat)
        #expect(snapshot.detail == "Your pull request")
        let push = Activity(threadId: 5, kind: .push, at: t(-minute), actor: me, commitCount: 1)
        let pushed = try #require(classify(pr, role: .author, details: makeDetails(for: pr, checks: checks, activity: [push]), links: [sent(pr)]))
        #expect(pushed.group == .answered)
        #expect(pushed.headline == "You pushed 1 commit")
        #expect(pushed.detail == "Dana Whitfield sent this in Teams")
        #expect(classify(pr, role: .author, details: makeDetails(for: pr, checks: checks, activity: [push]), links: [sent(pr)],
                         cutoff: t(-minute))?.group == .waiting)
    }

    @Test func aClosedPullRequestYouWerentOnIsntListed() {
        let closed = makePR(status: .completed, author: People.alex, closed: t(-minute))
        #expect(classify(closed, role: .linked, details: nil, links: [sent(closed)]) == nil)
    }

    @Test func itsNotAnnouncedButTheBriefMentionsIt() throws {
        let pr = makePR(author: People.alex)
        let snapshot = try #require(classify(pr, role: .linked, details: makeDetails(for: pr), links: [sent(pr)]))
        #expect(NotificationPlanner.plan(previous: [], current: [snapshot], notBefore: t(-day)).isEmpty)
        #expect(Brief.items(from: [snapshot]).first?.sentence == "Dana Whitfield sent you “Fix the checkout total” in Teams.")
    }
}

@Suite struct LinkedPullRequestEngineTests {
    @Test func readsEveryPullRequestYouWereSentInTurn() async throws {
        let server = StubServer()
        server.serveOrganization()
        let numbers = Array(101...112)
        for number in numbers {
            server.on("/contoso/_apis/git/pullrequests/\(number)", json: Fixture.pullRequest(number, author: People.alex))
        }
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])) { _ in }
        await engine.setLinkedPullRequests(Set(numbers.map { PRKey(Fixture.org, $0) }))
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().records.count == 10)
        // The next refresh reads the two left first, and keeps the others as they were read.
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().records.map(\.id.number) == numbers)
    }

    @Test func readsThemWithoutOrganizationsToWatch() async throws {
        let server = StubServer()
        server.on("/contoso/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/contoso/_apis/git/pullrequests/8", json: Fixture.pullRequest(8, author: People.alex))
        server.on("/_apis/policy/evaluations", json: Fixture.list([]))
        server.on("/threads", json: Fixture.list([]))
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [])) { _ in }
        await engine.setLinkedPullRequests([PRKey(Fixture.org, 8)])
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id.number) == [8])
        #expect(snapshot.records.first?.role == .linked)
        #expect(snapshot.problem == nil)
    }

    @Test func theyGoWithTheirLinks() async throws {
        let server = StubServer()
        server.on("/contoso/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        // Your own pull request, and one you review, in an organization you don't watch.
        server.on("/contoso/_apis/git/pullrequests/8", json: Fixture.pullRequest(8))
        server.on("/contoso/_apis/git/pullrequests/9", json: Fixture.pullRequest(9, author: People.alex, reviewers: [Fixture.reviewer(People.me)]))
        server.on("/_apis/policy/evaluations", json: Fixture.list([]))
        server.on("/threads", json: Fixture.list([]))
        let published = SnapshotCollector()
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [])) {
            published.add($0)
        }
        await engine.setLinkedPullRequests([PRKey(Fixture.org, 8), PRKey(Fixture.org, 9)])
        await engine.refreshNow()
        #expect(published.last?.records.map(\.role) == [.author, .reviewer])
        // They stay when you watch another organization, or none again.
        await engine.setConfiguration(PulseEngine.Configuration(organizations: ["fabrikam"]))
        #expect(published.last?.records.map(\.id.number) == [8, 9])
        await engine.setConfiguration(PulseEngine.Configuration(organizations: []))

        // A link goes, and its pull request with it, without waiting for a refresh.
        await engine.setLinkedPullRequests([PRKey(Fixture.org, 9)])
        #expect(published.last?.records.map(\.id.number) == [9])

        // The feature is turned off: there's nothing to read, or to list.
        await engine.setLinkedPullRequests([])
        #expect(published.last?.records.isEmpty == true)
        #expect(published.last?.problem == .noOrganizations)
        await engine.refreshNow()
        #expect(published.last?.records.isEmpty == true)
    }

    @Test func readsAPullRequestYouWereSentByItsID() async throws {
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1)])
        server.on("/contoso/_apis/git/pullrequests/8", json: Fixture.pullRequest(8, title: "Sent to me", author: People.alex))
        server.on("/contoso/_apis/git/pullrequests/9", json: Fixture.pullRequest(9, author: People.alex, status: "completed", closed: t(0)))
        server.on("/contoso/_apis/git/pullrequests/10") { _ in .status(404) }
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])) { _ in }
        await engine.setLinkedPullRequests([PRKey(Fixture.org, 1), PRKey(Fixture.org, 8), PRKey(Fixture.org, 9), PRKey(Fixture.org, 10)])
        await engine.refreshNow()

        let records = await engine.currentSnapshot().records
        #expect(records.map(\.id.number) == [1, 8])
        #expect(records.map(\.role) == [.author, .linked])
        #expect(records[1].details != nil)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })

        // The closed and unreadable ones aren't asked about again for an hour; the open one is, every refresh.
        let byID = { (id: Int) in server.requests.filter { $0.url?.path.hasSuffix("/pullrequests/\(id)") == true }.count }
        await engine.refreshNow()
        #expect(byID(8) == 2)
        #expect(byID(9) == 1)
        #expect(byID(10) == 1)
        // One already in your lists isn't read separately.
        #expect(byID(1) == 0)
    }
}
