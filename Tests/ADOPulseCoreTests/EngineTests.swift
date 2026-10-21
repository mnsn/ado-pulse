import Foundation
import Testing
@testable import ADOPulseCore

@Suite struct PlannerTests {
    private let options = RefreshPlanner.Options(busyInterval: 60, activeInterval: 180, quietInterval: 900, budget: 3)

    private func candidate(_ number: Int, _ fingerprint: String = "f") -> RefreshPlanner.Candidate {
        RefreshPlanner.Candidate(key: PRKey("contoso", number), fingerprint: fingerprint)
    }

    @Test func newAndChangedFirstThenTheOldestDue() {
        let cache: [PRKey: RefreshPlanner.Entry] = [
            PRKey("contoso", 2): .init(fetchedAt: t(-10), fingerprint: "old"),
            PRKey("contoso", 3): .init(fetchedAt: t(-61), fingerprint: "f", isBusy: true),
            PRKey("contoso", 4): .init(fetchedAt: t(-500), fingerprint: "f"),
            PRKey("contoso", 5): .init(fetchedAt: t(-200), fingerprint: "f"),
            PRKey("contoso", 6): .init(fetchedAt: t(-100), fingerprint: "f"),
            PRKey("contoso", 7): .init(fetchedAt: t(-800), fingerprint: "f", isQuiet: true),
            PRKey("contoso", 8): .init(fetchedAt: t(-901), fingerprint: "f", isQuiet: true),
        ]
        let candidates = (1...8).map { candidate($0) }
        let all = RefreshPlanner.plan(candidates, cache: cache, now: t(0), options: options, limit: nil)
        #expect(all.map(\.number) == [1, 2, 3, 8, 4, 5])
        // The budget is for refreshing known pull requests: new ones are always fetched.
        let budgeted = RefreshPlanner.plan(candidates, cache: cache, now: t(0), options: options, limit: 2)
        #expect(budgeted.map(\.number) == [1, 2, 3])
        let more = (9...12).map { candidate($0) }
        #expect(RefreshPlanner.plan(candidates + more, cache: cache, now: t(0), options: options, limit: 1).map(\.number) == [1, 9, 10, 11, 12, 2])
    }

    @Test func nothingIsDueRightAfterAFetch() {
        let cache = [PRKey("contoso", 1): RefreshPlanner.Entry(fetchedAt: t(0), fingerprint: "f", isBusy: true)]
        #expect(RefreshPlanner.plan([candidate(1)], cache: cache, now: t(30), options: options, limit: nil).isEmpty)
    }

    @Test func seenState() {
        var seen = SeenState.firstRun(now: t(0))
        let key = PRKey("contoso", 1)
        #expect(seen.baseline == t(-3 * day))
        #expect(seen.cutoff(for: key) == t(-3 * day))
        seen.markSeen([key], at: t(10))
        #expect(seen.cutoff(for: key) == t(10))
        // Never moves back.
        seen.markSeen([key], at: t(5))
        #expect(seen.cutoff(for: key) == t(10))

        seen.markSeen([PRKey("contoso", 2)], at: t(-40 * day))
        seen.markSeen([PRKey("contoso", 3)], at: t(-40 * day))
        seen.prune(keeping: [PRKey("contoso", 3)], olderThan: t(-30 * day))
        #expect(seen.seenAt.keys.sorted() == ["contoso/1", "contoso/3"])

        let data = try? JSONEncoder().encode(seen)
        #expect(data.flatMap { try? JSONDecoder().decode(SeenState.self, from: $0) } == seen)
    }
}

@Suite struct NotificationTests {
    private func snapshot(
        _ number: Int, group: PRGroup, reason: PRReason = .waitingForReviewers, role: PRRole = .author, events: [PREvent] = [],
        headline: String = "Headline", detail: String? = nil, hasDetails: Bool = true, since: Date = t(0)
    ) -> PRSnapshot {
        PRSnapshot(
            key: PRKey("contoso", number), title: "Pull request \(number)", repository: "shop-web", project: "Shop", author: "Sam Rivera",
            role: role, isDraft: false, group: group, reason: reason, headline: headline, detail: detail, since: since,
            url: URL(string: "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/\(number)")!, events: events,
            approvals: [], checkState: nil, hasDetails: hasDetails
        )
    }

    private let reply = PREvent(id: "c1.2", kind: .reply, at: t(10), actor: "Sam Rivera", text: "Cap it at 30 s", threadId: 1)

    @Test func announcesNewEventsOnce() {
        let before = [snapshot(1, group: .waiting)]
        let after = [snapshot(1, group: .needsYou, reason: .replied, events: [reply])]
        let notes = NotificationPlanner.plan(previous: before, current: after, notBefore: t(0))
        #expect(notes.map(\.title) == ["Sam Rivera replied"])
        #expect(notes.first?.subtitle == "Pull request 1")
        #expect(notes.first?.body == "Cap it at 30 s")
        #expect(NotificationPlanner.plan(previous: after, current: after, notBefore: t(0)).isEmpty)
    }

    @Test func eachEventLinksToItsOwnThread() {
        // The pull request's own link goes to the mention; the reply's notification goes to the reply.
        let mention = PREvent(id: "c2.1", kind: .mention, at: t(20), actor: "Priya Shah", text: "@Robin Diaz?", threadId: 2)
        let vote = PREvent(id: "v3", kind: .changesRequested, at: t(15), actor: "Alex Kim")
        var item = snapshot(1, group: .needsYou, reason: .mentioned, events: [mention, reply, vote])
        item.url = item.pageURL(thread: 2)
        let notes = NotificationPlanner.plan(previous: [snapshot(1, group: .waiting)], current: [item], notBefore: t(0))
        let links = Dictionary(uniqueKeysWithValues: notes.map { ($0.title, $0.url?.absoluteString) })
        #expect(links["Priya Shah mentioned you"] == item.pageURL(thread: 2).absoluteString)
        #expect(links["Sam Rivera replied"] == item.pageURL(thread: 1).absoluteString)
        #expect(links["Alex Kim is waiting for you"] == "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/1")
    }

    @Test func oldEventsArentAnnounced() {
        let after = [snapshot(1, group: .needsYou, events: [reply])]
        #expect(NotificationPlanner.plan(previous: [], current: after, notBefore: t(11)).isEmpty)
    }

    @Test func announcesYourPullRequestsFailingBecomingReadyAndCompleting() {
        let before = [snapshot(1, group: .waiting), snapshot(2, group: .waiting), snapshot(3, group: .ready), snapshot(4, group: .waiting)]
        let approval = PREvent(id: "v9", kind: .approved, at: t(5), actor: "Priya Shah")
        let after = [
            snapshot(1, group: .failing, reason: .buildFailed, headline: "Build failed", detail: "web-ci"),
            snapshot(2, group: .ready, reason: .readyToComplete, events: [approval], headline: "Ready to complete", detail: "Approved by Priya Shah"),
            snapshot(3, group: .done, reason: .completed, hasDetails: false),
            snapshot(4, group: .failing, reason: .buildExpired),
        ]
        let notes = NotificationPlanner.plan(previous: before, current: after, notBefore: t(0))
        #expect(Set(notes.map(\.title)) == ["Build failed", "Ready to complete", "Completed"])
        #expect(notes.first { $0.title == "Build failed" }?.body == "web-ci")
        #expect(notes.first { $0.title == "Ready to complete" }?.body == "Approved by Priya Shah")
    }

    @Test func aBuildThatFailsAgainIsNewsAgain() {
        let failing = { (since: Date) in
            [self.snapshot(1, group: .failing, reason: .buildFailed, headline: "Build failed", detail: "web-ci", since: since)]
        }
        let waiting = [snapshot(1, group: .waiting)]
        let first = NotificationPlanner.plan(previous: waiting, current: failing(t(10)), notBefore: t(0))
        let again = NotificationPlanner.plan(previous: waiting, current: failing(t(500)), notBefore: t(0))
        #expect(first.count == 1 && again.count == 1)
        #expect(first[0].id != again[0].id)
        #expect(first[0].key == PRKey("contoso", 1))
        // The same failure, back from Needs You once seen, has the same ID, so it isn't posted twice.
        let fromNeedsYou = NotificationPlanner.plan(previous: [snapshot(1, group: .needsYou)], current: failing(t(10)), notBefore: t(0))
        #expect(fromNeedsYou.map(\.id) == first.map(\.id))
    }

    @Test func eachPullRequestCanHaveItsOwnStartingPoint() {
        let comment = PREvent(id: "c1", kind: .comment, at: t(100), actor: "Sam Rivera")
        let current = [
            snapshot(1, group: .needsYou, events: [comment]),
            PRSnapshot(key: PRKey("fabrikam", 2), title: "Elsewhere", repository: "web", project: "P", author: "Sam Rivera", role: .author,
                       isDraft: false, group: .needsYou, reason: .commented, headline: "", since: t(100),
                       url: URL(string: "https://dev.azure.com/fabrikam")!, events: [comment], approvals: [], checkState: nil, hasDetails: true),
        ]
        // fabrikam was added at t(200): its earlier comment is in the panel, not news.
        let notes = NotificationPlanner.plan(previous: [], current: current) { $0.key.organization == "fabrikam" ? t(200) : t(0) }
        #expect(notes.map(\.key) == [PRKey("contoso", 1)])
    }

    @Test func reviewsYouDoArentAnnouncedAsYours() {
        let before = [snapshot(1, group: .toReview, role: .reviewer)]
        let after = [snapshot(1, group: .done, reason: .completed, role: .reviewer)]
        #expect(NotificationPlanner.plan(previous: before, current: after, notBefore: t(0)).isEmpty)
    }

    @Test func aPullRequestSeenForTheFirstTimeOnlyAnnouncesNewEvents() {
        let request = PREvent(id: "r3", kind: .reviewRequest, at: t(20), actor: "Sam Rivera", text: "Required reviewer")
        let after = [snapshot(5, group: .needsYou, reason: .reviewRequested, role: .reviewer, events: [request])]
        let notes = NotificationPlanner.plan(previous: [], current: after, notBefore: t(0))
        #expect(notes.map(\.title) == ["Review requested"])
        #expect(notes.first?.body == "Sam Rivera asked you to review (required reviewer).")
    }

    @Test func manyAtOnceAreSummarized() {
        let after = (1...6).map { number in
            snapshot(number, group: .needsYou, events: [PREvent(id: "c\(number)", kind: .comment, at: t(Double(number)), actor: "Sam Rivera")])
        }
        let notes = NotificationPlanner.plan(previous: [], current: after, notBefore: t(0), limit: 4)
        #expect(notes.count == 4)
        #expect(notes.prefix(3).map(\.subtitle) == ["Pull request 6", "Pull request 5", "Pull request 4"])
        #expect(notes.last?.body == "3 more pull request updates")
        #expect(notes.last?.url == nil)
    }

    @Test func briefSummarizesAcrossGroupsAndPromptsOneItemAtATime() {
        let mention = PREvent(id: "c1.1", kind: .mention, at: t(0), actor: "Priya Shah",
                              text: "@Robin Diaz can you check the cache headers?", threadId: 1)
        let snapshots = [
            snapshot(1, group: .waiting),
            snapshot(2, group: .ready, reason: .readyToComplete, since: t(-10)),
            snapshot(3, group: .needsYou, reason: .mentioned, events: [mention], since: t(-5)),
            snapshot(4, group: .failing, reason: .buildFailed, detail: "web-ci", since: t(-1)),
            snapshot(5, group: .ready, reason: .autoComplete, since: t(-2)),
            snapshot(6, group: .needsYou, reason: .reviewRequested, since: t(-20)),
        ]
        let items = Brief.items(from: snapshots, reader: "Robin Diaz")
        // The newest of each group, rather than everything that needs you.
        #expect(items.map(\.key.number) == [3, 4, 5])
        #expect(items[0].sentence == "Priya Shah mentioned you on “Pull request 3”.")
        #expect(items[0].prompt?.contains("Comment: you, can you check the cache headers?") == true)
        #expect(items[0].prompt?.contains("From: Priya Shah, who mentioned you") == true)
        #expect(items[1].sentence == "“Pull request 4” failed: web-ci.")
        #expect(items[1].prompt == nil)
        #expect(items[2].sentence == "“Pull request 5” is approved and will complete automatically.")

        // With fewer groups, more of what needs you.
        let needs = Brief.items(from: [snapshots[2], snapshots[5], snapshots[0]])
        #expect(needs.map(\.key.number) == [3, 6])
        #expect(needs[1].sentence == "Sam Rivera asked you to review “Pull request 6”.")
    }
}

@Suite struct EngineTests {
    private func engine(_ server: StubServer, organizations: [String] = [Fixture.org], collector: SnapshotCollector? = nil,
                        tokens: (any AccessTokenProvider)? = nil, budget: Int = 8) -> PulseEngine {
        PulseEngine(
            client: server.client(tokens: tokens),
            configuration: PulseEngine.Configuration(organizations: organizations, planner: RefreshPlanner.Options(budget: budget))
        ) { collector?.add($0) }
    }

    private func classify(_ snapshot: PulseSnapshot, now: Date = Date()) -> [Int: PRSnapshot] {
        let seen = SeenState.firstRun(now: now)
        var result: [Int: PRSnapshot] = [:]
        for record in snapshot.records {
            if let item = PRClassifier.snapshot(for: record, seenCutoff: seen.cutoff(for: record.id), now: now) {
                result[record.id.number] = item
            }
        }
        return result
    }

    @Test func loadsListsAndDetailsWithGETRequestsOnly() async throws {
        let now = Date()
        let server = StubServer()
        server.serveOrganization(
            mine: [Fixture.pullRequest(1, title: "Mine", reviewers: [Fixture.reviewer(People.sam, vote: 10)],
                                       created: now.addingTimeInterval(-day))],
            reviewing: [
                Fixture.pullRequest(2, title: "Theirs", author: People.sam, reviewers: [Fixture.reviewer(People.me)],
                                    created: now.addingTimeInterval(-hour)),
                // Your own pull request shows up here when you're a reviewer on it too; it's yours.
                Fixture.pullRequest(1, title: "Mine", created: now.addingTimeInterval(-day)),
            ],
            completed: [Fixture.pullRequest(3, title: "Merged", created: now.addingTimeInterval(-day), status: "completed",
                                            closed: now.addingTimeInterval(-hour))]
        )
        server.on("/_apis/policy/evaluations", query: ["artifactId": "vstfs:///CodeReview/CodeReviewId/p1/1"], json: Fixture.list([
            Fixture.evaluation("Build", status: "rejected", settings: ["displayName": "web-ci"], context: ["buildId": 4, "isExpired": false]),
        ]))
        server.on("/pullRequests/2/threads", json: Fixture.list([
            Fixture.thread(7, comments: [Fixture.comment(1, People.sam, "Hi @<\(People.me.id)>", at: now.addingTimeInterval(-minute))],
                           published: now.addingTimeInterval(-minute)),
        ]))

        let snapshot = await PulseEngine.loadOnce(
            client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])
        )
        #expect(snapshot.problem == nil)
        #expect(snapshot.hasLoaded)
        #expect(snapshot.records.map(\.id.number) == [1, 2, 3])
        #expect(snapshot.records.map(\.role) == [.author, .reviewer, .author])
        #expect(snapshot.records.allSatisfy { $0.me == People.me.id })
        #expect(snapshot.records[0].details != nil && snapshot.records[1].details != nil)
        #expect(snapshot.records[2].details == nil)

        let items = classify(snapshot, now: now)
        #expect(items[1]?.group == .failing)
        #expect(items[2]?.reason == .mentioned)
        #expect(items[2]?.detail == "Hi @Robin Diaz")
        #expect(items[3]?.group == .done)

        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        // connectionData, three lists, and two requests for each of the two active pull requests.
        #expect(server.requests.count == 8)
    }

    @Test func policiesYouCantReadAreUnknownNotNone() async throws {
        let now = Date()
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1, reviewers: [Fixture.reviewer(People.sam, vote: 10)],
                                                            created: now.addingTimeInterval(-day))])
        server.on("/_apis/policy/evaluations") { _ in .status(403) }
        let snapshot = await PulseEngine.loadOnce(
            client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])
        )
        let details = try #require(snapshot.records.first?.details)
        #expect(!details.checksKnown)
        #expect(classify(snapshot, now: now)[1]?.group == .waiting)
    }

    @Test func reportsSigningInProblems() async {
        let server = StubServer()
        server.serveOrganization()
        let signedOut = await PulseEngine.loadOnce(
            client: server.client(tokens: FakeTokens(server.id, error: .signedOut("Run az login"))),
            configuration: PulseEngine.Configuration(organizations: [Fixture.org])
        )
        #expect(signedOut.problem == .signedOut("Run az login"))
        #expect(signedOut.problem?.needsSignIn == true)
        #expect(server.requests.isEmpty)

        let missing = await PulseEngine.loadOnce(
            client: server.client(tokens: FakeTokens(server.id, error: .cliNotFound)),
            configuration: PulseEngine.Configuration(organizations: [Fixture.org])
        )
        #expect(missing.problem == .cliNotFound)

        let none = await PulseEngine.loadOnce(client: server.client(), configuration: PulseEngine.Configuration(organizations: []))
        #expect(none.problem == .noOrganizations)
    }

    @Test func keepsTheLastListWhenAzureDevOpsCannotBeReached() async throws {
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1)])
        let engine = engine(server)
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().records.count == 1)

        server.on("/_apis/git/pullrequests") { _ in .failure(.notConnectedToInternet) }
        await engine.refreshNow()
        let offline = await engine.currentSnapshot()
        #expect(offline.problem == .offline)
        #expect(offline.records.count == 1)
    }

    @Test func reportsAnOrganizationThatCannotBeRead() async {
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1)])
        server.on("/locked/_apis/connectionData") { _ in .status(403) }
        let snapshot = await PulseEngine.loadOnce(
            client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org, "locked"])
        )
        #expect(snapshot.records.count == 1)
        #expect(snapshot.problem == .someOrganizations("Couldn't read locked (No access to this organization.)."))
    }

    @Test func anOrganizationRemovedDuringARefreshStaysRemoved() async throws {
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1)])
        server.serveOrganization("slow", mine: [Fixture.pullRequest(2)])
        server.on("/slow/_apis/git/pullrequests") { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return .json(Fixture.list([Fixture.pullRequest(2)]))
        }
        let engine = PulseEngine(
            client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org, "slow"])
        ) { _ in }
        async let refresh: Void = engine.refreshNow()
        try await Task.sleep(for: .milliseconds(150))
        await engine.setConfiguration(PulseEngine.Configuration(organizations: [Fixture.org]))
        await refresh
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id) == [PRKey(Fixture.org, 1)])
        #expect(Set(snapshot.firstLoaded.keys) == [Fixture.org])
    }

    @Test func fetchesDetailsOnABudgetAfterTheFirstLoad() async {
        let server = StubServer()
        server.serveOrganization(mine: (1...5).map { Fixture.pullRequest($0) })
        let engine = engine(server, budget: 2)
        await engine.refreshNow()
        let detailRequests = { server.requests.filter { $0.url?.path.hasSuffix("/threads") == true }.count }
        #expect(detailRequests() == 5)

        // Nothing changed and nothing's due: only the lists.
        await engine.refreshNow()
        #expect(detailRequests() == 5)

        // Two pushes: at most two details per refresh.
        server.on("/_apis/git/pullrequests", query: ["searchCriteria.status": "active", "searchCriteria.creatorId": Fixture.me],
                  json: Fixture.list((1...5).map { Fixture.pullRequest($0, sourceCommit: $0 <= 3 ? "pushed" : "abc") }))
        await engine.refreshNow()
        #expect(detailRequests() == 7)
        await engine.refreshNow()
        #expect(detailRequests() == 8)
    }

    @Test func findsOutWhatHappenedToAPullRequestThatLeftTheList() async throws {
        let now = Date()
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1), Fixture.pullRequest(2)])
        let engine = engine(server)
        await engine.refreshNow()

        server.on("/_apis/git/pullrequests", query: ["searchCriteria.status": "active", "searchCriteria.creatorId": Fixture.me],
                  json: Fixture.list([Fixture.pullRequest(2)]))
        server.on("/_apis/git/pullrequests/1", json: Fixture.pullRequest(1, status: "abandoned", closed: now.addingTimeInterval(-minute)))
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.pullRequest.status) == [.abandoned, .active])
        #expect(classify(snapshot, now: now)[1]?.reason == .abandoned)
    }

    @Test func keepsLookingUpPullRequestsThatLeftTheList() async throws {
        let now = Date()
        let server = StubServer()
        let numbers = Array(1...7)
        server.serveOrganization(mine: numbers.map { Fixture.pullRequest($0) })
        let engine = engine(server)
        await engine.refreshNow()

        // All seven were abandoned at once, more than a refresh looks up, and reading one fails the first time.
        server.on("/_apis/git/pullrequests", query: ["searchCriteria.status": "active", "searchCriteria.creatorId": Fixture.me],
                  json: Fixture.list([]))
        let attempts = Locked(0)
        for number in numbers {
            server.on("/_apis/git/pullrequests/\(number)") { _ in
                if number == 1, attempts.increment() == 1 { return .status(500) }
                return .json(Fixture.pullRequest(number, status: "abandoned", closed: now.addingTimeInterval(-minute)))
            }
        }
        await engine.refreshNow()
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id.number) == numbers)
        #expect(snapshot.records.allSatisfy { $0.pullRequest.status == .abandoned })
        #expect(attempts.value == 2)
    }

    @Test func backsOffWhenThrottled() async {
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1)])
        server.on("/threads") { _ in .status(429, headers: ["Retry-After": "120"]) }
        let snapshot = await PulseEngine.loadOnce(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org]))
        guard case .throttled(let until)? = snapshot.problem else {
            Issue.record("Expected throttled, got \(String(describing: snapshot.problem))")
            return
        }
        #expect(until.timeIntervalSinceNow > 100)
    }

    @Test(.timeLimit(.minutes(1)))
    func refreshesOnATimerAndWhenAsked() async throws {
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1)])
        let collector = SnapshotCollector()
        let engine = PulseEngine(
            client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org], interval: 3_600)
        ) { collector.add($0) }
        await engine.start()
        defer { Task { await engine.stop() } }
        try await collector.wait("the first load") { $0.hasLoaded && !$0.isRefreshing && $0.records.count == 1 }

        server.on("/_apis/git/pullrequests", query: ["searchCriteria.status": "active", "searchCriteria.creatorId": Fixture.me],
                  json: Fixture.list([Fixture.pullRequest(1), Fixture.pullRequest(2)]))
        engine.refresh()
        try await collector.wait("the refresh it asked for") { $0.records.count == 2 && !$0.isRefreshing }
    }

    @Test(.timeLimit(.minutes(1)))
    func aWakeBeforeTheWaitStillWakesIt() async {
        let waker = Waker()
        waker.wake()
        let start = Date()
        await waker.wait(for: 30)
        #expect(Date().timeIntervalSince(start) < 5)
        let timed = Date()
        await waker.wait(for: 0.2)
        #expect(Date().timeIntervalSince(timed) >= 0.15)
    }
}
