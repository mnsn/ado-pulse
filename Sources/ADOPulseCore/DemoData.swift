import Foundation

/// Made-up pull requests in every state, for working on the UI and taking screenshots without showing
/// real ones (`--demo`, `make demo`, `make screenshots`). Times are relative to `now`.
public enum DemoData {
    public static let organization = "contoso"
    public static let me = Person(id: "6f1c1a52-0000-4000-8000-00000000a001", name: "Robin Diaz")

    /// The groups the demo pull requests land in; `make demo-check` compares them with the app's.
    public static let expectedCounts: [String: Int] = [
        "needsYou": 3, "failing": 2, "ready": 2, "toReview": 1, "waiting": 2, "done": 1, "idle": 2,
    ]

    private static let sam = person("b001", "Sam Rivera")
    private static let priya = person("b002", "Priya Shah")
    private static let alex = person("b003", "Alex Kim")
    private static let jordan = person("b004", "Jordan Lee")
    private static let maria = person("b005", "Maria Garcia")
    private static let chen = person("b006", "Chen Wei")
    private static let buildService = Person(id: "6f1c1a52-0000-4000-8000-00000000c001", name: "Storefront Build Service", isBot: true)

    private static func person(_ suffix: String, _ name: String) -> Person {
        Person(id: "6f1c1a52-0000-4000-8000-00000000\(suffix)", name: name)
    }

    /// The first-run seen state: only the last three days are new.
    public static func seenState(now: Date = Date()) -> SeenState {
        SeenState.firstRun(now: now)
    }

    public static func snapshot(now: Date = Date()) -> PulseSnapshot {
        PulseSnapshot(
            records: records(now: now), organizations: [organization], problem: nil,
            refreshedAt: now.addingTimeInterval(-20), isRefreshing: false, hasLoaded: true
        )
    }

    public static func records(now: Date) -> [PRRecord] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let hour = 60.0
        let day = 24 * hour

        func pr(
            _ number: Int, _ title: String, repo: String, author: Person = me, created: Date, reviewers: [Reviewer] = [],
            branch: String = "feature", draft: Bool = false, merge: String = "succeeded", autoComplete: Bool = false,
            status: PullRequest.Status = .active, closed: Date? = nil
        ) -> PullRequest {
            PullRequest(
                key: PRKey(organization, number), title: title, status: status, author: author, createdAt: created, closedAt: closed,
                projectId: "7a0c4e1d-0000-4000-8000-000000000001", projectName: "Storefront",
                repositoryId: "repository-\(repo)", repositoryName: repo,
                sourceBranch: branch, targetBranch: "main", isDraft: draft, mergeStatus: merge, reviewers: reviewers,
                autoComplete: autoComplete, sourceCommit: "c\(number)", targetCommit: "t1"
            )
        }
        func record(_ pr: PullRequest, role: PRRole = .author, checks: [Check] = [], threads: [ReviewThread] = [],
                    activity: [Activity] = []) -> PRRecord {
            let dates = threads.flatMap { $0.comments.map(\.publishedAt) } + activity.map(\.at)
            let details = PRDetails(
                fetchedAt: now, fingerprint: pr.fingerprint, checks: checks, threads: threads, activity: activity,
                lastActivity: dates.max()
            )
            return PRRecord(pullRequest: pr, role: role, details: pr.status == .active ? details : nil, me: me.id)
        }
        func reviewer(_ person: Person, _ vote: Vote = .none, required: Bool = false) -> Reviewer {
            Reviewer(person: person, vote: vote, isRequired: required)
        }
        func comment(_ id: Int, _ author: Person, _ text: String, _ at: Date, mentions: [Person] = []) -> ReviewComment {
            ReviewComment(id: id, author: author, text: text, mentions: mentions.map(\.id), publishedAt: at)
        }
        func vote(_ thread: Int, _ person: Person, _ vote: Vote, _ at: Date) -> Activity {
            Activity(threadId: thread, kind: .vote, at: at, actor: person, vote: vote)
        }
        func added(_ thread: Int, _ person: Person, by: Person, _ at: Date) -> Activity {
            Activity(threadId: thread, kind: .reviewersChanged, at: at, actor: by, added: [person.id])
        }
        let build = { (name: String, state: Check.State, completed: Date?) in
            Check(name: name, kind: .build, state: state, completedAt: completed)
        }
        let minimumReviewers = { (state: Check.State, minimum: Int) in
            Check(name: "Minimum number of reviewers", kind: .reviewers, state: state, minimumApprovers: minimum)
        }
        let mergeStrategy = Check(name: "Require a merge strategy", kind: .completion, state: .pending)

        return [
            // Needs you: a reply to your comment.
            record(
                pr(4102, "Add retry with backoff to the payments client", repo: "payments-api", created: ago(26 * hour),
                   reviewers: [reviewer(sam, required: true), reviewer(priya, .approved)], branch: "payments-retry"),
                checks: [build("payments-api CI", .passed, ago(5 * hour)), minimumReviewers(.pending, 2),
                         Check(name: "Comment requirements", kind: .requirement, state: .pending), mergeStrategy],
                threads: [ReviewThread(id: 11, filePath: "/src/PaymentsClient.cs", line: 88, comments: [
                    comment(1, me, "I went with exponential backoff, starting at 200 ms and doubling each time.", ago(3 * hour)),
                    comment(2, sam, "Could we cap the backoff at 30 seconds? Otherwise a slow dependency can stall checkout "
                        + "for minutes, and the load balancer gives up after 60 seconds anyway.", ago(12)),
                ])],
                activity: [vote(12, priya, .approved, ago(5 * hour))]
            ),
            // Needs you: a mention on a pull request you review.
            record(
                pr(4097, "Move image resizing to a background queue", repo: "shop-web", author: alex, created: ago(2 * day),
                   reviewers: [reviewer(me), reviewer(maria, .approved)], branch: "resize-queue"),
                role: .reviewer,
                checks: [build("shop-web CI", .passed, ago(2 * day))],
                threads: [ReviewThread(id: 21, comments: [
                    comment(1, alex, "@Robin Diaz could you double-check the cache headers? I'm not sure 24 hours is right "
                        + "for thumbnails that change when a seller edits a listing.", ago(25), mentions: [me]),
                ])],
                activity: [added(22, me, by: alex, ago(2 * day))]
            ),
            // Needs you: a new review request.
            record(
                pr(4110, "Upgrade the build agents to .NET 9", repo: "infra", author: jordan, created: ago(40),
                   reviewers: [reviewer(me, required: true), reviewer(chen)], branch: "dotnet-9"),
                role: .reviewer,
                checks: [build("infra CI", .running, nil)],
                activity: [added(31, me, by: jordan, ago(40))]
            ),
            // Failing: a build failed (the build service's comment about it doesn't need you).
            record(
                pr(4088, "Show delivery estimates on the product page", repo: "shop-web", created: ago(50 * hour),
                   reviewers: [reviewer(maria, .approved)], branch: "delivery-estimates"),
                checks: [build("shop-web CI", .failed, ago(65)), minimumReviewers(.passed, 1)],
                threads: [ReviewThread(id: 41, status: "closed", comments: [
                    comment(1, buildService, "2 tests failed in DeliveryEstimateTests.", ago(64)),
                ])],
                activity: [vote(42, maria, .approved, ago(20 * hour))]
            ),
            // Failing: merge conflicts.
            record(
                pr(4079, "Rename the order status enum", repo: "payments-api", created: ago(4 * day),
                   reviewers: [reviewer(chen)], branch: "rename-order-status", merge: "conflicts"),
                checks: [build("payments-api CI", .passed, ago(30 * hour)), minimumReviewers(.pending, 1)],
                activity: [Activity(threadId: 51, kind: .push, at: ago(30 * hour), actor: me, commitCount: 2)]
            ),
            // Ready to complete.
            record(
                pr(4091, "Fix the coupon rounding error", repo: "payments-api", created: ago(30 * hour),
                   reviewers: [reviewer(priya, .approved), reviewer(chen, .approved)], branch: "coupon-rounding"),
                checks: [build("payments-api CI", .passed, ago(4 * hour)), minimumReviewers(.passed, 2),
                         Check(name: "Comment requirements", kind: .requirement, state: .passed), mergeStrategy],
                activity: [vote(61, priya, .approved, ago(3 * hour)), vote(62, chen, .approved, ago(50))]
            ),
            // Ready, completing automatically.
            record(
                pr(4093, "Add dark mode to the account page", repo: "shop-web", created: ago(2 * day),
                   reviewers: [reviewer(maria, .approvedWithSuggestions)], branch: "account-dark-mode", autoComplete: true),
                checks: [build("shop-web CI", .passed, ago(2 * hour)), minimumReviewers(.passed, 1)],
                activity: [vote(71, maria, .approvedWithSuggestions, ago(2 * hour))]
            ),
            // To review: a request from before the last three days, so it's been seen.
            record(
                pr(4071, "Cache product search results", repo: "search", author: chen, created: ago(5 * day),
                   reviewers: [reviewer(me), reviewer(alex, .approved)], branch: "search-cache"),
                role: .reviewer,
                checks: [build("search CI", .passed, ago(5 * day))],
                activity: [added(81, me, by: chen, ago(5 * day))]
            ),
            // Waiting for reviewers while the build runs.
            record(
                pr(4099, "Log slow database queries", repo: "infra", created: ago(90),
                   reviewers: [reviewer(alex), reviewer(jordan)], branch: "slow-query-log"),
                checks: [build("infra CI", .running, nil), minimumReviewers(.pending, 2)],
                activity: [Activity(threadId: 91, kind: .push, at: ago(20), actor: me, commitCount: 1)]
            ),
            // Waiting for the author: you asked for changes.
            record(
                pr(4060, "Add rate limiting to the public API", repo: "payments-api", author: sam, created: ago(6 * day),
                   reviewers: [reviewer(me, .waitingForAuthor), reviewer(priya)], branch: "rate-limits"),
                role: .reviewer,
                checks: [build("payments-api CI", .passed, ago(6 * day))],
                threads: [ReviewThread(id: 101, comments: [
                    comment(1, me, "The limit should be per API key rather than per IP address.", ago(day)),
                ])],
                activity: [vote(102, me, .waitingForAuthor, ago(day))]
            ),
            // Done: completed two hours ago.
            record(pr(4085, "Update the README badges", repo: "shop-web", created: ago(day), status: .completed, closed: ago(2 * hour))),
            // Idle: a draft.
            record(
                pr(4105, "Prototype one-click checkout", repo: "shop-web", created: ago(3 * hour), branch: "one-click", draft: true),
                checks: [build("shop-web CI", .notRun, nil)]
            ),
            // Idle: no activity for weeks.
            record(
                pr(3990, "Remove the legacy coupon API", repo: "payments-api", created: ago(40 * day),
                   reviewers: [reviewer(priya)], branch: "remove-legacy-coupons"),
                checks: [build("payments-api CI", .expired, ago(23 * day))],
                threads: [ReviewThread(id: 111, comments: [
                    comment(1, priya, "Do any partners still call the v1 endpoint?", ago(23 * day)),
                ])]
            ),
        ]
    }
}
