import Foundation
import Testing
@testable import ADOPulseCore

@Suite struct DetailsTests {
    private func check(_ json: [String: Any]) throws -> Check? {
        Check(try Fixture.decode(ADOPolicyEvaluation.self, json))
    }

    @Test func buildPolicies() throws {
        func build(_ status: String, context: [String: Any]? = ["buildId": 1, "isExpired": false]) throws -> Check.State? {
            try check(Fixture.evaluation("Build", status: status, settings: ["displayName": "CI"], context: context))?.state
        }
        #expect(try build("approved") == .passed)
        #expect(try build("rejected") == .failed)
        #expect(try build("broken") == .failed)
        #expect(try build("running") == .running)
        #expect(try build("queued") == .queued)
        #expect(try build("queued", context: ["buildId": 1, "isExpired": true]) == .expired)
        #expect(try build("rejected", context: ["buildId": 1, "isExpired": true]) == .expired)
        #expect(try build("queued", context: nil) == .notRun)
        #expect(try build("notApplicable") == .notApplicable)

        let named = try #require(try check(Fixture.evaluation("Build", status: "approved", context: ["buildDefinitionName": "web-ci"])))
        #expect(named.name == "web-ci")
        #expect(named.kind == .build)
        let unnamed = try #require(try check(Fixture.evaluation("Build", status: "approved")))
        #expect(unnamed.name == "Build")
    }

    @Test func statusPolicies() throws {
        let failed = try #require(try check(Fixture.evaluation("Status", status: "rejected",
                                                               settings: ["statusGenre": "security", "statusName": "scan"])))
        #expect(failed.kind == .status)
        #expect(failed.state == .failed)
        #expect(failed.name == "security/scan")
        let named = try #require(try check(Fixture.evaluation("Status", status: "queued", settings: ["defaultDisplayName": "License check"])))
        #expect(named.name == "License check")
        #expect(named.state == .pending)
    }

    /// Requirements that aren't met yet are reported as "rejected": they're pending, not failures.
    @Test func requirementPolicies() throws {
        let cases: [(String, Check.Kind)] = [
            ("Minimum number of reviewers", .reviewers), ("Required reviewers", .reviewers), ("Proof Of Presence", .reviewers),
            ("Work item linking", .requirement), ("Comment requirements", .requirement), ("Something new", .requirement),
            ("Require a merge strategy", .completion),
        ]
        for (type, kind) in cases {
            let pending = try #require(try check(Fixture.evaluation(type, status: "rejected")))
            #expect(pending.kind == kind)
            #expect(pending.state == .pending)
            #expect(try check(Fixture.evaluation(type, status: "approved"))?.state == .passed)
        }
        let minimum = try check(Fixture.evaluation("Minimum number of reviewers", status: "queued", blocking: false,
                                                   settings: ["minimumApproverCount": 2]))
        #expect(minimum?.minimumApprovers == 2)
        #expect(minimum?.isBlocking == false)
        // Disabled policies are left out.
        #expect(try check(Fixture.evaluation("Build", status: "rejected", enabled: false)) == nil)
    }

    @Test func separatesConversationsFromActivity() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.sam, vote: .approved)])
        let threads = try Fixture.decode(ADOList<ADOThread>.self, Fixture.list([
            Fixture.thread(1, comments: [
                Fixture.comment(1, People.sam, "Please **rename** `x`", at: t(-3 * hour)),
                Fixture.comment(2, People.me, "Done", at: t(-2 * hour)),
                Fixture.comment(3, People.sam, "Deleted", at: t(-90 * minute), deleted: true),
                Fixture.comment(4, People.sam, "Status changed", at: t(-80 * minute), type: "system"),
            ], status: "fixed", published: t(-3 * hour), filePath: "/src/Cart/Total.cs"),
            Fixture.activity(2, "VoteUpdate", at: t(-hour), by: People.sam, properties: ["CodeReviewVoteResult": "10"]),
            Fixture.activity(3, "RefUpdate", at: t(-30 * minute), by: People.me, properties: ["CodeReviewRefNewCommitsCount": "2"]),
            Fixture.activity(4, "ReviewersUpdate", at: t(-4 * hour), by: People.me,
                             properties: ["CodeReviewReviewersUpdatedAddedIdentity": "2"],
                             identities: ["2": Fixture.identity(People.priya)]),
            Fixture.activity(5, "ResetMultipleVotes", at: t(-20 * minute), by: People.me),
            Fixture.thread(6, comments: [Fixture.comment(1, People.sam, "Only deleted", at: t(-hour), deleted: true)], published: t(-hour)),
        ]))
        let details = PRDetails(fetchedAt: t(0), pullRequest: pr, evaluations: [], threads: threads.value)

        #expect(details.threads.count == 1)
        let thread = try #require(details.threads.first)
        #expect(thread.comments.map(\.text) == ["Please rename x", "Done"])
        #expect(thread.fileName == "Total.cs")
        #expect(thread.line == 12)
        #expect(thread.isResolved)
        #expect(thread.comments.first?.author.name == "Sam Rivera")

        #expect(details.activity.map(\.kind) == [.reviewersChanged, .vote, .push, .votesReset])
        #expect(details.activity[0].added == [People.priya.id])
        #expect(details.activity[1].vote == .approved)
        #expect(details.activity[1].actor == People.sam)
        #expect(details.activity[2].commitCount == 2)
        #expect(details.lastActivity == t(-20 * minute))
        #expect(details.fingerprint == pr.fingerprint)
    }

    @Test func recognizesServiceIdentities() {
        #expect(Person(ADOIdentity(id: "1", displayName: "Shop Build Service (contoso)", uniqueName: "Build\\1234")).isBot)
        #expect(Person(ADOIdentity(id: "1", displayName: "Release Bot", uniqueName: nil)).isBot)
        #expect(Person(ADOIdentity(id: "1", displayName: "Team", uniqueName: "[Shop]\\Team", isContainer: true)).isBot)
        #expect(!Person(ADOIdentity(id: "1", displayName: "Sam Rivera", uniqueName: "sam@contoso.com")).isBot)
        #expect(!Person(ADOIdentity(id: "1", displayName: "Sam Rivera", uniqueName: nil)).isBot)
    }

    @Test(arguments: [
        ("Sam Rivera", "Sam"), ("Rivera, Sam", "Sam"), ("Sam", "Sam"), ("  ", ""),
    ])
    func firstNames(_ name: String, _ expected: String) {
        #expect(Person(id: "1", name: name).firstName == expected)
    }

    @Test func plainCommentText() {
        let names = [People.me.id: "Robin Diaz"]
        let mention = "@<\(People.me.id.uppercased())> can you **check** [the docs](https://example.com)?"
        #expect(CommentText.plain(mention, names: names) == "@Robin Diaz can you check the docs?")
        #expect(CommentText.mentionedIds(mention) == [People.me.id])
        #expect(CommentText.plain("@<\(People.sam.id)> hi", names: [:]) == "@someone hi")
        #expect(CommentText.plain("<div>Use&nbsp;<b>Task</b> &amp; await</div>", names: [:]) == "Use Task & await")
        #expect(CommentText.plain("Try:\n```csharp\nvar x = 1;\n```\nthanks", names: [:]) == "Try: var x = 1; thanks")
        let long = String(repeating: "word ", count: 200)
        let short = CommentText.plain(long, names: [:], limit: 50)
        #expect(short.count == 50)
        #expect(short.hasSuffix("…"))
    }

    @Test func fingerprintFollowsWhatTheListReports() {
        let base = makePR(reviewers: [Reviewer(person: People.sam, vote: .none)])
        var voted = base
        voted.reviewers[0].vote = .approved
        var pushed = base
        pushed.sourceCommit = "new"
        var conflicted = base
        conflicted.mergeStatus = "conflicts"
        let prints = [base, voted, pushed, conflicted].map(\.fingerprint)
        #expect(Set(prints).count == 4)
        #expect(base.fingerprint == makePR(reviewers: [Reviewer(person: People.sam, vote: .none)]).fingerprint)
    }
}

@Suite struct ClassifierTests {
    private let me = People.me
    private let cutoff = t(-3 * day)

    private func classify(
        _ pr: PullRequest, role: PRRole = .author, details: PRDetails? = nil, cutoff: Date? = nil, now: Date = t(0),
        options: ClassifierOptions = ClassifierOptions()
    ) -> PRSnapshot? {
        PRClassifier.snapshot(
            for: PRRecord(pullRequest: pr, role: role, details: details, me: me.id), seenCutoff: cutoff ?? self.cutoff, now: now, options: options
        )
    }

    private func passing(_ extra: [Check] = []) -> [Check] {
        [Check(name: "CI", kind: .build, state: .passed), Check(name: "Minimum number of reviewers", kind: .reviewers, state: .passed)] + extra
    }

    // MARK: Needs you

    @Test func aReplyToYourCommentNeedsYou() throws {
        let pr = makePR()
        let thread = ReviewThread(id: 5, comments: [
            comment(1, People.sam, "Why?", at: t(-5 * hour)),
            comment(2, me, "Because", at: t(-4 * hour)),
            comment(3, People.sam, "Makes sense, but cap it", at: t(-10 * minute)),
        ])
        let snapshot = try #require(classify(pr, details: makeDetails(for: pr, checks: passing(), threads: [thread])))
        #expect(snapshot.group == .needsYou)
        #expect(snapshot.reason == .replied)
        #expect(snapshot.headline == "Sam Rivera replied")
        #expect(snapshot.detail == "Makes sense, but cap it")
        #expect(snapshot.since == t(-10 * minute))
        #expect(snapshot.url == pr.threadURL(5))
        #expect(snapshot.events.map(\.id) == ["c5.3"])
    }

    @Test func answeringOrSeeingItClearsIt() throws {
        let pr = makePR()
        let answered = ReviewThread(id: 5, comments: [
            comment(1, People.sam, "Cap it?", at: t(-hour)), comment(2, me, "Done", at: t(-30 * minute)),
        ])
        let snapshot = try #require(classify(pr, details: makeDetails(for: pr, checks: passing(), threads: [answered])))
        #expect(snapshot.group == .ready)

        let unanswered = ReviewThread(id: 5, comments: [comment(1, People.sam, "Cap it?", at: t(-hour))])
        let details = makeDetails(for: pr, checks: passing(), threads: [unanswered])
        #expect(classify(pr, details: details)?.group == .needsYou)
        #expect(classify(pr, details: details, cutoff: t(-hour))?.group == .ready)
    }

    @Test func newCommentsOnYourPullRequestNeedYou() throws {
        let pr = makePR()
        let threads = [
            ReviewThread(id: 1, comments: [comment(1, People.sam, "Nit: typo", at: t(-2 * hour))]),
            ReviewThread(id: 2, comments: [comment(1, People.priya, "Add a test?", at: t(-hour))]),
            ReviewThread(id: 3, comments: [comment(1, People.bot, "2 tests failed", at: t(-minute))]),
        ]
        let snapshot = try #require(classify(pr, details: makeDetails(for: pr, checks: passing(), threads: threads)))
        #expect(snapshot.reason == .commented)
        #expect(snapshot.headline == "2 new comments")
        #expect(snapshot.detail == "Add a test?")
        // The bot's comment isn't counted.
        #expect(snapshot.events.count == 2)
        #expect(snapshot.since == t(-hour))
    }

    @Test func mentionsComeFirst() throws {
        let pr = makePR(author: People.sam)
        let threads = [
            ReviewThread(id: 1, comments: [comment(1, me, "Question", at: t(-3 * hour)), comment(2, People.sam, "Answer", at: t(-minute))]),
            ReviewThread(id: 2, comments: [comment(1, People.priya, "@Robin Diaz thoughts?", at: t(-hour), mentions: [me])]),
            // Comments between others don't concern you as a reviewer.
            ReviewThread(id: 3, comments: [comment(1, People.priya, "Hmm", at: t(-minute))]),
        ]
        let snapshot = try #require(classify(pr, role: .reviewer, details: makeDetails(for: pr, threads: threads)))
        #expect(snapshot.reason == .mentioned)
        #expect(snapshot.headline == "Priya Shah mentioned you")
        #expect(snapshot.url == pr.threadURL(2))
        #expect(Set(snapshot.events.map(\.kind)) == [.mention, .reply])
    }

    @Test func reviewRequests() throws {
        let pr = makePR(author: People.sam, created: t(-2 * day), reviewers: [Reviewer(person: me, vote: .none, isRequired: true)])
        let added = Activity(threadId: 9, kind: .reviewersChanged, at: t(-hour), actor: People.sam, added: [me.id])
        let fresh = try #require(classify(pr, role: .reviewer, details: makeDetails(for: pr, activity: [added])))
        #expect(fresh.group == .needsYou)
        #expect(fresh.reason == .reviewRequested)
        #expect(fresh.detail == "Required reviewer")
        #expect(fresh.since == t(-hour))

        // Once seen, it waits in To Review.
        let seen = try #require(classify(pr, role: .reviewer, details: makeDetails(for: pr, activity: [added]), cutoff: t(0)))
        #expect(seen.group == .toReview)
        #expect(seen.headline == "Required review")
        #expect(seen.detail == "By Sam Rivera")

        // Without a record of when you were added, the creation date counts: older than the cutoff here.
        let old = makePR(author: People.sam, created: t(-5 * day), reviewers: [Reviewer(person: me, vote: .none)])
        #expect(classify(old, role: .reviewer, details: makeDetails(for: old, lastActivity: t(-day)))?.group == .toReview)

        // A draft becoming ready for review asks again.
        let published = Activity(threadId: 10, kind: .draftChanged, at: t(-2 * hour), actor: People.sam)
        #expect(classify(old, role: .reviewer, details: makeDetails(for: old, activity: [published]))?.reason == .reviewRequested)
    }

    @Test func newCommitsSinceYourVote() throws {
        let pr = makePR(author: People.sam, reviewers: [Reviewer(person: me, vote: .waitingForAuthor)])
        let voted = Activity(threadId: 1, kind: .vote, at: t(-day), actor: me, vote: .waitingForAuthor)
        let pushes = [
            Activity(threadId: 2, kind: .push, at: t(-2 * hour), actor: People.sam, commitCount: 2),
            Activity(threadId: 3, kind: .push, at: t(-hour), actor: People.sam, commitCount: 1),
        ]
        let snapshot = try #require(classify(pr, role: .reviewer, details: makeDetails(for: pr, activity: [voted] + pushes)))
        #expect(snapshot.reason == .newCommits)
        #expect(snapshot.headline == "3 new commits since your vote")
        #expect(snapshot.events.map(\.id) == ["p3"])

        let quiet = try #require(classify(pr, role: .reviewer, details: makeDetails(for: pr, activity: [voted])))
        #expect(quiet.group == .waiting)
        #expect(quiet.reason == .waitingForAuthor)
        #expect(quiet.detail == "You asked Sam Rivera for changes")
    }

    @Test func votesThatWantChanges() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.sam, vote: .waitingForAuthor), Reviewer(person: People.priya, vote: .rejected)])
        let votes = [
            Activity(threadId: 1, kind: .vote, at: t(-2 * hour), actor: People.sam, vote: .waitingForAuthor),
            Activity(threadId: 2, kind: .vote, at: t(-hour), actor: People.priya, vote: .rejected),
        ]
        let snapshot = try #require(classify(pr, details: makeDetails(for: pr, checks: passing(), activity: votes)))
        #expect(snapshot.group == .needsYou)
        #expect(snapshot.reason == .rejected)
        #expect(snapshot.headline == "Priya Shah rejected it")
        #expect(snapshot.pendingEvents.count == 2)

        // Once you've pushed changes, it's their turn: it waits.
        let pushed = votes + [Activity(threadId: 3, kind: .push, at: t(-minute), actor: me, commitCount: 1)]
        let after = try #require(classify(pr, details: makeDetails(for: pr, checks: passing(), activity: pushed)))
        #expect(after.group == .waiting)
        #expect(after.reason == .rejected)
        #expect(after.detail == "Sam Rivera, Priya Shah")

        // A vote that has since changed isn't news.
        var changed = pr
        changed.reviewers = [Reviewer(person: People.sam, vote: .approved), Reviewer(person: People.priya, vote: .approved)]
        let old = try #require(classify(changed, details: makeDetails(for: changed, checks: passing(), activity: votes)))
        #expect(old.group == .ready)
        #expect(old.events.isEmpty)
    }

    @Test func votesFromRemovedReviewersDontCount() throws {
        // Sam asked for changes and Priya approved, and then both were removed from the pull request.
        let pr = makePR(reviewers: [Reviewer(person: People.alex, vote: .none)])
        let votes = [
            Activity(threadId: 1, kind: .vote, at: t(-2 * hour), actor: People.sam, vote: .waitingForAuthor),
            Activity(threadId: 2, kind: .vote, at: t(-hour), actor: People.priya, vote: .approved),
        ]
        let snapshot = try #require(classify(pr, details: makeDetails(for: pr, checks: passing(), activity: votes)))
        #expect(snapshot.group != .needsYou)
        #expect(snapshot.events.isEmpty)
    }

    @Test func approvalsAreNewsButDontNeedYou() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.sam, vote: .approved)])
        let approval = Activity(threadId: 4, kind: .vote, at: t(-hour), actor: People.sam, vote: .approved)
        let snapshot = try #require(classify(pr, details: makeDetails(for: pr, checks: passing(), activity: [approval])))
        #expect(snapshot.group == .ready)
        #expect(snapshot.events.map(\.kind) == [.approved])
        #expect(snapshot.pendingEvents.isEmpty)
        #expect(snapshot.approvals == ["Sam Rivera"])
    }

    // MARK: Failing, ready and waiting

    @Test func failures() throws {
        let pr = makePR()
        func state(_ checks: [Check], merge: String = "succeeded") throws -> (PRGroup, PRReason, String, String?) {
            var copy = pr
            copy.mergeStatus = merge
            let snapshot = try #require(classify(copy, details: makeDetails(for: copy, checks: checks, lastActivity: t(-hour))))
            return (snapshot.group, snapshot.reason, snapshot.headline, snapshot.detail)
        }
        let failedBuild = Check(name: "web-ci", kind: .build, state: .failed, completedAt: t(-hour))
        #expect(try state([failedBuild]) == (.failing, .buildFailed, "Build failed", "web-ci"))
        #expect(try state([failedBuild], merge: "conflicts") == (.failing, .buildFailed, "Build failed", "web-ci · merge conflicts"))
        #expect(try state([failedBuild, Check(name: "api-ci", kind: .build, state: .failed)]).2 == "2 builds failed")
        #expect(try state([Check(name: "scan", kind: .status, state: .failed)]) == (.failing, .checkFailed, "Check failed", "scan"))
        #expect(try state([], merge: "conflicts") == (.failing, .conflicts, "Merge conflicts", "fix-total into main"))
        #expect(try state([Check(name: "web-ci", kind: .build, state: .expired)]) == (.failing, .buildExpired, "Build expired", "web-ci · queue it again"))
        // An optional build doesn't count.
        let optional = Check(name: "perf", kind: .build, state: .failed, isBlocking: false)
        #expect(try state(passing([optional])).0 == .ready)
    }

    @Test func readyToComplete() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.sam, vote: .approved), Reviewer(person: People.priya, vote: .approvedWithSuggestions)])
        let mergeStrategy = Check(name: "Require a merge strategy", kind: .completion, state: .pending)
        let snapshot = try #require(classify(pr, details: makeDetails(for: pr, checks: passing([mergeStrategy]), lastActivity: t(-hour))))
        #expect(snapshot.group == .ready)
        #expect(snapshot.reason == .readyToComplete)
        #expect(snapshot.detail == "Approved by Sam Rivera, Priya Shah")
        #expect(snapshot.checkState == .passed)

        var auto = pr
        auto.autoComplete = true
        #expect(classify(auto, details: makeDetails(for: auto, checks: passing(), lastActivity: t(-hour)))?.headline == "Completing automatically")

        // Without any reviewer policy, an approval is what makes it ready.
        let noPolicy = makePR()
        let build = [Check(name: "CI", kind: .build, state: .passed)]
        #expect(classify(noPolicy, details: makeDetails(for: noPolicy, checks: build, lastActivity: t(-hour)))?.group == .waiting)
        var approved = noPolicy
        approved.reviewers = [Reviewer(person: People.sam, vote: .approved)]
        #expect(classify(approved, details: makeDetails(for: approved, checks: build, lastActivity: t(-hour)))?.group == .ready)
    }

    @Test func readyOnlyWithCurrentReadablePolicies() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.sam, vote: .approved)])
        let details = makeDetails(for: pr, checks: passing(), lastActivity: t(-hour))
        let ready = try #require(classify(pr, details: details))
        #expect(ready.group == .ready)

        // A push since the details were read: their passing checks may not apply any more.
        var pushed = pr
        pushed.sourceCommit = "abd"
        let outdated = try #require(classify(pushed, details: details))
        #expect(outdated.group == .waiting)
        #expect(outdated.headline == "Waiting for reviewers")
        // And it isn't announced as ready.
        let before = try #require(classify(pushed, details: makeDetails(for: pushed, checks: [Check(name: "CI", kind: .build, state: .running)])))
        #expect(NotificationPlanner.plan(previous: [before], current: [outdated], notBefore: t(-day)).isEmpty)

        // A project whose policies you can't read: nobody can tell it's ready.
        let unreadable = try #require(classify(pr, details: makeDetails(for: pr, checksKnown: false, lastActivity: t(-hour))))
        #expect(unreadable.group == .waiting)
        #expect(unreadable.headline == "Can't read its policies")
        #expect(unreadable.detail == "Approved by Sam Rivera")
    }

    @Test func waiting() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.sam, vote: .approved)])
        func describe(_ checks: [Check]) throws -> (PRReason, String, String?) {
            let snapshot = try #require(classify(pr, details: makeDetails(for: pr, checks: checks, lastActivity: t(-hour))))
            #expect(snapshot.group == .waiting)
            return (snapshot.reason, snapshot.headline, snapshot.detail)
        }
        let reviewers = Check(name: "Minimum number of reviewers", kind: .reviewers, state: .pending, minimumApprovers: 2)
        let running = Check(name: "web-ci", kind: .build, state: .running)
        #expect(try describe([reviewers, running]) == (.waitingForReviewers, "Waiting for reviewers", "1 of 2 approvals · build running"))
        #expect(try describe([running]).0 == .checksRunning)
        #expect(try describe([running]).1 == "Build running")
        #expect(try describe([Check(name: "license", kind: .status, state: .pending)]).1 == "Checks running")
        #expect(try describe([Check(name: "web-ci", kind: .build, state: .notRun)]) == (.requirementsPending, "Build hasn't run", "web-ci · queue it"))
        #expect(try describe([Check(name: "Work item linking", kind: .requirement, state: .pending)]).1 == "Link a work item")
        #expect(try describe([Check(name: "Comment requirements", kind: .requirement, state: .pending)]).1 == "Resolve comments")
        #expect(try describe([Check(name: "Proof Of Presence", kind: .reviewers, state: .pending)]).2 == "Approved by Sam Rivera")
    }

    @Test func withoutDetailsItWaits() throws {
        let snapshot = try #require(classify(makePR()))
        #expect(snapshot.group == .waiting)
        #expect(!snapshot.hasDetails)
        #expect(snapshot.checkState == nil)
        // Merge conflicts are in the list itself.
        #expect(classify(makePR(merge: "conflicts"))?.group == .failing)
    }

    // MARK: Done and idle

    @Test func completedPullRequestsStayInDoneForADay() throws {
        let completed = makePR(status: .completed, closed: t(-2 * hour))
        let snapshot = try #require(classify(completed))
        #expect(snapshot.group == .done)
        #expect(snapshot.reason == .completed)
        #expect(snapshot.detail == "Merged into main")
        #expect(snapshot.since == t(-2 * hour))
        #expect(classify(completed, now: t(22 * hour)) != nil)
        #expect(classify(completed, now: t(22 * hour + 1)) == nil)
        // Cleared or opened since.
        #expect(classify(completed, cutoff: t(-hour)) == nil)
        #expect(classify(makePR(status: .abandoned, closed: t(-hour)))?.reason == .abandoned)
    }

    @Test func idle() throws {
        let draft = makePR(draft: true)
        #expect(classify(draft, details: makeDetails(for: draft))?.reason == .draft)

        let old = makePR(created: t(-40 * day))
        let stale = makeDetails(for: old, checks: [Check(name: "CI", kind: .build, state: .failed)], lastActivity: t(-20 * day))
        let snapshot = try #require(classify(old, details: stale))
        #expect(snapshot.group == .idle)
        #expect(snapshot.headline == "No activity for 20 days")
        #expect(classify(old, details: stale, options: ClassifierOptions(inactiveAfter: nil))?.group == .failing)

        // New activity on an old pull request still needs you.
        let reply = ReviewThread(id: 1, comments: [comment(1, People.sam, "Ping", at: t(-hour))])
        #expect(classify(old, details: makeDetails(for: old, threads: [reply]))?.group == .needsYou)

        let approvedByMe = makePR(author: People.sam, reviewers: [Reviewer(person: me, vote: .approved), Reviewer(person: People.priya, vote: .approved)])
        let approved = try #require(classify(approvedByMe, role: .reviewer, details: makeDetails(for: approvedByMe, lastActivity: t(-hour))))
        #expect(approved.group == .idle)
        #expect(approved.reason == .youApproved)
        #expect(approved.detail == "Also approved by Priya Shah")

        let declined = makePR(author: People.sam, reviewers: [Reviewer(person: me, vote: .none, hasDeclined: true)])
        #expect(classify(declined, role: .reviewer, details: makeDetails(for: declined, lastActivity: t(-hour)))?.reason == .declined)
    }

    // MARK: Ordering and counts

    @Test func ordersByGroupThenMostRecent() throws {
        func item(_ number: Int, _ group: PRGroup, _ since: Date?) -> PRSnapshot {
            var snapshot = try! #require(classify(makePR(number)))
            snapshot.group = group
            snapshot.since = since
            return snapshot
        }
        let items = [
            item(1, .idle, t(-1)), item(2, .waiting, t(-50)), item(3, .needsYou, t(-30)), item(4, .needsYou, t(-10)),
            item(5, .failing, t(-5)), item(6, .waiting, t(-5)), item(7, .done, nil), item(8, .ready, t(-1)), item(9, .toReview, t(0)),
        ]
        #expect(PROrdering.sorted(items.shuffled()).map(\.key.number) == [4, 3, 5, 8, 9, 6, 2, 7, 1])
        let counts = GroupCounts(items)
        #expect(PRGroup.allCases.map { counts[$0] } == [2, 1, 1, 1, 2, 1, 1])
        #expect(counts.active == 8)
    }

    @Test(arguments: [
        (0.0, "now"), (59, "now"), (60, "1m"), (3_599, "59m"), (3_600, "1h"), (3_660, "1h 1m"),
        (86_399, "23h 59m"), (86_400, "1d"), (200_000, "2d"), (-5, "now"),
    ])
    func formatsElapsedTime(_ seconds: TimeInterval, _ expected: String) {
        #expect(Elapsed.short(since: t(0), now: t(seconds)) == expected)
    }

    @Test func theDemoDataCoversEveryGroup() {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        let snapshots = DemoData.records(now: now).compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), now: now)
        }
        let counts = GroupCounts(snapshots)
        for group in PRGroup.allCases {
            #expect(counts[group] == DemoData.expectedCounts[group.rawValue], "\(group)")
        }
        // The build service's comment on the failing pull request doesn't need you.
        #expect(snapshots.first { $0.key.number == 4088 }?.group == .failing)

        // A minute later, a new comment: announced once, and the pull request needs you.
        let later = now.addingTimeInterval(60)
        let updated = DemoData.update(DemoData.snapshot(now: now), at: later).records.compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), now: later)
        }
        #expect(updated.first { $0.key.number == 4091 }?.group == .needsYou)
        let notes = NotificationPlanner.plan(previous: snapshots, current: updated, notBefore: now)
        #expect(notes.map(\.title) == ["Priya Shah commented"])
        #expect(notes.first?.subtitle == "Fix the coupon rounding error")
    }
}
