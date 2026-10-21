import Foundation

/// The groups the panel shows, in display order.
public enum PRGroup: String, Sendable, Codable, CaseIterable, Comparable {
    /// Something new for you: a reply, a mention, a comment, a review request, a vote that wants changes.
    case needsYou
    /// Your pull requests with a failed build or check, merge conflicts or an expired build.
    case failing
    /// Your pull requests that are approved and pass every required check.
    case ready
    /// Review requests you've seen but haven't voted on.
    case toReview
    /// Your pull requests waiting on reviewers or checks, and reviews waiting on their author.
    case waiting
    /// Completed or abandoned recently.
    case done
    /// Nothing to do: drafts, pull requests without recent activity, reviews you've approved or declined.
    case idle

    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: PRGroup, rhs: PRGroup) -> Bool { lhs.rank < rhs.rank }
}

/// Why a pull request is in its group. A reason can appear in more than one group: a vote that wants
/// changes needs you until you've seen it, and then it waits.
public enum PRReason: String, Sendable, Codable {
    case mentioned, sentInChat, replied, commented, reviewRequested, newCommits, changesRequested, rejected
    case buildFailed, checkFailed, conflicts, buildExpired
    case readyToComplete, autoComplete
    case reviewPending
    case waitingForReviewers, checksRunning, requirementsPending, waitingForAuthor
    case completed, abandoned
    case draft, inactive, youApproved, declined
}

/// Something that happened that you haven't seen yet. Approvals are news, but don't need you.
public struct PREvent: Sendable, Codable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case mention, sentInChat, reply, comment, reviewRequest, newCommits, changesRequested, rejected, approved

        public var needsYou: Bool { self != .approved }

        /// Which event names the pull request's reason when it has several.
        var priority: Int {
            switch self {
            case .mention: return 0
            case .sentInChat: return 1
            case .reply: return 2
            case .rejected: return 3
            case .changesRequested: return 4
            case .comment: return 5
            case .reviewRequest: return 6
            case .newCommits: return 7
            case .approved: return 8
            }
        }
    }

    /// Stable across refreshes, so each event is announced once.
    public var id: String
    public var kind: Kind
    public var at: Date
    public var actor: String?
    public var text: String?
    public var threadId: Int?
    /// New commits, for `newCommits`.
    public var count: Int?
    /// The app it was sent in, for `sentInChat`: "Teams".
    public var app: String?

    public init(
        id: String, kind: Kind, at: Date, actor: String? = nil, text: String? = nil, threadId: Int? = nil, count: Int? = nil,
        app: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.at = at
        self.actor = actor
        self.text = text
        self.threadId = threadId
        self.count = count
        self.app = app
    }
}

/// A pull request as the engine knows it: from the list, plus its details once fetched.
public struct PRRecord: Sendable, Equatable, Identifiable {
    public var pullRequest: PullRequest
    public var role: PRRole
    public var details: PRDetails?
    /// Your identity ID in the pull request's organization.
    public var me: String
    /// Links to it that people sent you.
    public var chatLinks: [ChatLink]

    public var id: PRKey { pullRequest.key }

    public init(pullRequest: PullRequest, role: PRRole, details: PRDetails? = nil, me: String, chatLinks: [ChatLink] = []) {
        self.pullRequest = pullRequest
        self.role = role
        self.details = details
        self.me = me.lowercased()
        self.chatLinks = chatLinks
    }
}

/// What the panel shows for one pull request.
public struct PRSnapshot: Sendable, Codable, Equatable, Identifiable {
    public var key: PRKey
    public var title: String
    public var repository: String
    public var project: String
    public var author: String
    public var role: PRRole
    public var isDraft: Bool
    public var group: PRGroup
    public var reason: PRReason
    public var headline: String
    /// A comment, the names of failed checks, who approved...
    public var detail: String?
    /// When it entered this state, or the latest activity.
    public var since: Date?
    /// The pull request, or the thread of the comment that needs you.
    public var url: URL
    /// What you haven't seen yet, newest first.
    public var events: [PREvent]
    /// People who approved.
    public var approvals: [String]
    /// The state of the required builds and status checks together, worst first; nil without any.
    public var checkState: Check.State?
    public var hasDetails: Bool
    /// Where it was sent to you, while that needs you.
    public var chatSource: ChatSource? = nil

    public var id: String { key.description }

    /// Events that need you, rather than news such as approvals.
    public var pendingEvents: [PREvent] { events.filter(\.kind.needsYou) }
}

/// The message that sent you a pull request: the app, who, and a link to the message when there is one.
public struct ChatSource: Sendable, Codable, Equatable {
    /// The app's bundle identifier.
    public var app: String
    public var appName: String
    public var sender: String?
    /// Opens the message itself (Teams); otherwise the app is just brought forward.
    public var messageURL: URL?

    public init(app: String, appName: String, sender: String?, messageURL: URL?) {
        self.app = app
        self.appName = appName
        self.sender = sender
        self.messageURL = messageURL
    }
}

public struct ClassifierOptions: Sendable, Equatable {
    /// Pull requests without activity for this long go to Idle; nil keeps them where they are.
    public var inactiveAfter: TimeInterval?
    /// How long completed and abandoned pull requests stay in Done.
    public var keepDoneFor: TimeInterval
    /// How long a pull request someone sent you keeps needing you, unless you act on it sooner.
    public var keepChatLinksFor: TimeInterval

    public init(inactiveAfter: TimeInterval? = 14 * 86_400, keepDoneFor: TimeInterval = 86_400, keepChatLinksFor: TimeInterval = 7 * 86_400) {
        self.inactiveAfter = inactiveAfter
        self.keepDoneFor = keepDoneFor
        self.keepChatLinksFor = keepChatLinksFor
    }
}

/// Decides each pull request's group, reason and unseen events.
public enum PRClassifier {
    /// `seenCutoff`: activity up to this time counts as seen. Nil when the pull request shouldn't be listed:
    /// done a while ago, or done and already seen.
    public static func snapshot(
        for record: PRRecord, seenCutoff: Date, now: Date, options: ClassifierOptions = ClassifierOptions()
    ) -> PRSnapshot? {
        let pr = record.pullRequest
        let me = record.me
        let details = record.details
        let approvals = pr.reviewers.filter { $0.vote.isApproval && !$0.isGroup }
        let lastActivity = max(pr.createdAt, details?.lastActivity ?? .distantPast)

        var snapshot = PRSnapshot(
            key: pr.key, title: pr.title.isEmpty ? "Pull request \(pr.key.number)" : pr.title,
            repository: pr.repositoryName, project: pr.projectName, author: pr.author.name, role: record.role,
            isDraft: pr.isDraft, group: .waiting, reason: .waitingForReviewers, headline: "", detail: nil,
            since: lastActivity, url: pr.webURL, events: [], approvals: approvals.map(\.person.name),
            checkState: details.flatMap { checkState($0.checks) }, hasDetails: details != nil
        )
        func set(_ group: PRGroup, _ reason: PRReason, _ headline: String, _ detail: String? = nil, since: Date? = nil) {
            snapshot.group = group
            snapshot.reason = reason
            snapshot.headline = headline
            snapshot.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
            snapshot.since = since ?? lastActivity
        }

        switch pr.status {
        case .completed, .abandoned:
            // Done is for your own pull requests.
            guard record.role == .author else { return nil }
            let closed = pr.closedAt ?? lastActivity
            guard now.timeIntervalSince(closed) <= options.keepDoneFor, closed > seenCutoff else { return nil }
            let completed = pr.status == .completed
            set(.done, completed ? .completed : .abandoned, completed ? "Completed" : "Abandoned",
                completed ? "Merged into \(pr.targetBranch)" : nil, since: closed)
            return snapshot
        case .other:
            return nil
        case .active:
            break
        }

        var events: [PREvent] = []
        if let details {
            events = record.role == .author
                ? authorEvents(pr, details, me: me, seenCutoff: seenCutoff)
                : reviewerEvents(pr, details, me: me, seenCutoff: seenCutoff)
        }
        let chats = pendingChatLinks(record, seenCutoff: seenCutoff, now: now, options: options)
        events += chats.map { link in
            PREvent(id: "s" + link.id, kind: .sentInChat, at: link.sentAt, actor: link.sender, app: link.appName)
        }
        snapshot.events = events.sorted { $0.at > $1.at }
        if let newest = chats.max(by: { $0.sentAt < $1.sentAt }) {
            snapshot.chatSource = ChatSource(app: newest.app, appName: newest.appName, sender: newest.sender, messageURL: newest.messageURL)
        }
        let pending = snapshot.pendingEvents
        if let top = pending.min(by: { ($0.kind.priority, -$0.at.timeIntervalSince1970) < ($1.kind.priority, -$1.at.timeIntervalSince1970) }) {
            let (reason, headline) = describe(top, among: pending)
            set(.needsYou, reason, headline, top.text ?? eventDetail(top, pr, role: record.role), since: pending.map(\.at).max())
            if let thread = top.threadId { snapshot.url = pr.threadURL(thread) }
            return snapshot
        }
        // A pull request you're not on is listed only while someone's message about it needs you.
        if record.role == .linked { return nil }

        if record.role == .reviewer, pr.reviewer(me)?.hasDeclined == true {
            set(.idle, .declined, "You declined")
            return snapshot
        }
        if pr.isDraft {
            set(.idle, .draft, "Draft", record.role == .reviewer ? "By \(pr.author.name)" : nil)
            return snapshot
        }
        if let inactiveAfter = options.inactiveAfter, now.timeIntervalSince(lastActivity) > inactiveAfter {
            let days = Int(now.timeIntervalSince(lastActivity) / 86_400)
            set(.idle, .inactive, "No activity for \(days) days")
            return snapshot
        }

        switch record.role {
        case .author:
            classifyAuthor(pr, details, approvals: approvals, lastActivity: lastActivity, set: set)
        case .reviewer, .linked:
            classifyReviewer(pr, me: me, approvals: approvals, set: set)
        }
        return snapshot
    }

    // MARK: Events

    /// On your pull request: comments from others that came after your last word in their thread, and
    /// votes that are still standing.
    static func authorEvents(_ pr: PullRequest, _ details: PRDetails, me: String, seenCutoff: Date) -> [PREvent] {
        var events: [PREvent] = []
        for thread in details.threads {
            let lastMine = thread.comments.last { $0.author.id == me }?.publishedAt
            for comment in unanswered(thread, me: me, after: max(seenCutoff, lastMine ?? .distantPast)) {
                let kind: PREvent.Kind = comment.mentions.contains(me) ? .mention : lastMine != nil ? .reply : .comment
                events.append(event(kind, comment, in: thread))
            }
        }

        var latestVotes: [String: Activity] = [:]
        for item in details.activity where item.kind == .vote {
            if let id = item.actor?.id, id != me { latestVotes[id] = item }
        }
        let lastPush = details.activity.last { $0.kind == .push }?.at
        for (id, item) in latestVotes {
            guard let vote = item.vote, item.at > seenCutoff else { continue }
            // Only a vote that still stands.
            if let reviewer = pr.reviewer(id), reviewer.vote != vote { continue }
            let kind: PREvent.Kind
            switch vote {
            case .approved, .approvedWithSuggestions: kind = .approved
            case .waitingForAuthor, .rejected:
                // You've pushed changes since.
                if let lastPush, lastPush > item.at { continue }
                kind = vote == .rejected ? .rejected : .changesRequested
            case .none: continue
            }
            events.append(PREvent(id: "v\(item.threadId)", kind: kind, at: item.at, actor: item.actor?.name))
        }
        return events
    }

    /// On a pull request you review: replies and mentions, a review request you haven't seen, and pushes
    /// since your vote.
    static func reviewerEvents(_ pr: PullRequest, _ details: PRDetails, me: String, seenCutoff: Date) -> [PREvent] {
        var events: [PREvent] = []
        for thread in details.threads {
            let lastMine = thread.comments.last { $0.author.id == me }?.publishedAt
            for comment in unanswered(thread, me: me, after: max(seenCutoff, lastMine ?? .distantPast)) {
                if comment.mentions.contains(me) {
                    events.append(event(.mention, comment, in: thread))
                } else if lastMine != nil {
                    events.append(event(.reply, comment, in: thread))
                }
            }
        }

        let votedAt = details.activity.last { $0.kind == .vote && $0.actor?.id == me && $0.vote != Vote.none }?.at
        let current = pr.reviewer(me)
        if let votedAt {
            let pushes = details.activity.filter { $0.kind == .push && $0.at > votedAt && $0.at > seenCutoff }
            if let latest = pushes.last {
                let commits = pushes.compactMap(\.commitCount).reduce(0, +)
                events.append(PREvent(id: "p\(latest.threadId)", kind: .newCommits, at: latest.at, actor: pr.author.name,
                                      count: commits > 0 ? commits : nil))
            }
        } else if let current, current.vote == .none, !current.hasDeclined, !pr.isDraft {
            // Asked to review, from when you were added (or the draft was published).
            let added = details.activity.last { $0.kind == .reviewersChanged && $0.added.contains(me) }
            let published = details.activity.last { $0.kind == .draftChanged }?.at ?? .distantPast
            let at = max(added?.at ?? pr.createdAt, published)
            if at > seenCutoff {
                events.append(PREvent(
                    id: "r\(added?.threadId ?? 0)", kind: .reviewRequest, at: at, actor: pr.author.name,
                    text: current.isRequired ? "Required reviewer" : nil
                ))
            }
        }
        return events
    }

    /// Links people sent you that still need you: sent after you last looked, in the last week, and not
    /// followed by your comment, vote or (on your own pull request) push.
    static func pendingChatLinks(_ record: PRRecord, seenCutoff: Date, now: Date, options: ClassifierOptions) -> [ChatLink] {
        record.chatLinks.filter { link in
            guard link.sentAt > seenCutoff, now.timeIntervalSince(link.sentAt) <= options.keepChatLinksFor else { return false }
            guard let details = record.details else { return true }
            let me = record.me
            let commented = details.threads.contains { thread in
                thread.comments.contains { $0.author.id == me && $0.publishedAt > link.sentAt }
            }
            let acted = details.activity.contains { item in
                guard item.at > link.sentAt, item.actor?.id == me else { return false }
                return item.kind == .vote || (record.role == .author && item.kind == .push)
            }
            return !commented && !acted
        }
    }

    /// Comments from people (not bots), other than you, published after `date`.
    private static func unanswered(_ thread: ReviewThread, me: String, after date: Date) -> [ReviewComment] {
        thread.comments.filter { $0.author.id != me && !$0.author.isBot && $0.publishedAt > date }
    }

    private static func event(_ kind: PREvent.Kind, _ comment: ReviewComment, in thread: ReviewThread) -> PREvent {
        PREvent(id: "c\(thread.id).\(comment.id)", kind: kind, at: comment.publishedAt, actor: comment.author.name,
                text: comment.text, threadId: thread.id)
    }

    private static func describe(_ top: PREvent, among events: [PREvent]) -> (PRReason, String) {
        let actor = top.actor ?? "Someone"
        let sameKind = events.filter { $0.kind == top.kind }.count
        switch top.kind {
        case .mention: return (.mentioned, "\(actor) mentioned you")
        case .sentInChat:
            let app = top.app ?? "a chat"
            return (.sentInChat, top.actor.map { "\($0) sent this in \(app)" } ?? "Sent to you in \(app)")
        case .reply: return (.replied, sameKind > 1 ? "\(sameKind) new replies" : "\(actor) replied")
        case .comment: return (.commented, sameKind > 1 ? "\(sameKind) new comments" : "\(actor) commented")
        case .reviewRequest: return (.reviewRequested, "Review requested")
        case .newCommits:
            let count = top.count.map { $0 == 1 ? "1 new commit" : "\($0) new commits" } ?? "New commits"
            return (.newCommits, "\(count) since your vote")
        case .changesRequested: return (.changesRequested, "\(actor) is waiting for you")
        case .rejected: return (.rejected, "\(actor) rejected it")
        case .approved: return (.readyToComplete, "\(actor) approved")
        }
    }

    private static func eventDetail(_ event: PREvent, _ pr: PullRequest, role: PRRole) -> String? {
        switch event.kind {
        case .reviewRequest: return "By \(pr.author.name)"
        case .newCommits: return "By \(pr.author.name)"
        case .sentInChat: return role == .author ? "Your pull request" : "By \(pr.author.name)"
        default: return nil
        }
    }

    // MARK: States

    private static func classifyAuthor(
        _ pr: PullRequest, _ details: PRDetails?, approvals: [Reviewer], lastActivity: Date,
        set: (PRGroup, PRReason, String, String?, Date?) -> Void
    ) {
        let checks = details?.checks ?? []
        let blocking = checks.filter { $0.isBlocking && $0.kind != .completion && $0.state != .notApplicable }
        func names(_ checks: [Check]) -> String { checks.map(\.name).joined(separator: ", ") }
        func latestCompletion(_ checks: [Check]) -> Date? { checks.compactMap(\.completedAt).max() }

        let failedBuilds = blocking.filter { $0.kind == .build && $0.state == .failed }
        let failedChecks = blocking.filter { $0.kind == .status && $0.state == .failed }
        let expired = blocking.filter { $0.kind == .build && $0.state == .expired }
        let conflicts = pr.hasConflicts ? " · merge conflicts" : ""
        if !failedBuilds.isEmpty {
            set(.failing, .buildFailed, failedBuilds.count > 1 ? "\(failedBuilds.count) builds failed" : "Build failed",
                names(failedBuilds + failedChecks) + conflicts, latestCompletion(failedBuilds))
            return
        }
        if !failedChecks.isEmpty {
            set(.failing, .checkFailed, failedChecks.count > 1 ? "\(failedChecks.count) checks failed" : "Check failed",
                names(failedChecks) + conflicts, latestCompletion(failedChecks))
            return
        }
        if pr.hasConflicts {
            set(.failing, .conflicts, "Merge conflicts", "\(pr.sourceBranch) into \(pr.targetBranch)", nil)
            return
        }
        if !expired.isEmpty {
            set(.failing, .buildExpired, "Build expired", names(expired) + " · queue it again", nil)
            return
        }

        let wantChanges = pr.reviewers.filter { $0.vote.wantsChanges && !$0.isGroup }
        if let first = wantChanges.first(where: { $0.vote == .rejected }) ?? wantChanges.first {
            let who = wantChanges.map(\.person.name).joined(separator: ", ")
            set(.waiting, first.vote == .rejected ? .rejected : .changesRequested,
                first.vote == .rejected ? "Rejected" : "Changes requested", who, nil)
            return
        }

        let running = blocking.filter { ($0.kind == .build || $0.kind == .status) && [.running, .queued, .pending].contains($0.state) }
        let notRun = blocking.filter { $0.kind == .build && $0.state == .notRun }
        let reviewersPending = blocking.filter { $0.kind == .reviewers && $0.state != .passed }
        let requirements = blocking.filter { $0.kind == .requirement && $0.state != .passed }
        let hasReviewerPolicy = checks.contains { $0.kind == .reviewers && $0.isBlocking }
        let approvedBy = approvals.isEmpty ? nil : "Approved by " + approvals.map(\.person.name).joined(separator: ", ")

        if details != nil, running.isEmpty, notRun.isEmpty, reviewersPending.isEmpty, requirements.isEmpty,
           hasReviewerPolicy || !approvals.isEmpty {
            set(.ready, pr.autoComplete ? .autoComplete : .readyToComplete,
                pr.autoComplete ? "Completing automatically" : "Ready to complete",
                approvedBy ?? "No approvals required", nil)
            return
        }

        var progress: [String] = []
        if let minimum = reviewersPending.compactMap(\.minimumApprovers).max(), minimum > 0 {
            progress.append("\(approvals.count) of \(minimum) approvals")
        } else if let approvedBy {
            progress.append(approvedBy)
        } else {
            progress.append("No approvals yet")
        }
        if !running.isEmpty {
            progress.append(running.contains { $0.kind == .build } ? "build running" : "checks running")
        }

        if details == nil {
            set(.waiting, .waitingForReviewers, "Waiting for reviewers", progress.first, nil)
        } else if !reviewersPending.isEmpty || (!hasReviewerPolicy && approvals.isEmpty) {
            set(.waiting, .waitingForReviewers, "Waiting for reviewers", progress.joined(separator: " · "), nil)
        } else if !running.isEmpty {
            let builds = running.filter { $0.kind == .build }
            set(.waiting, .checksRunning, builds.isEmpty ? "Checks running" : "Build running", names(running), nil)
        } else if !notRun.isEmpty {
            set(.waiting, .requirementsPending, "Build hasn't run", names(notRun) + " · queue it", nil)
        } else {
            set(.waiting, .requirementsPending, requirementHeadline(requirements), progress.first, nil)
        }
    }

    private static func classifyReviewer(
        _ pr: PullRequest, me: String, approvals: [Reviewer], set: (PRGroup, PRReason, String, String?, Date?) -> Void
    ) {
        let mine = pr.reviewer(me)
        switch mine?.vote ?? .none {
        case .approved, .approvedWithSuggestions:
            let others = approvals.filter { $0.person.id != me }.map(\.person.name)
            set(.idle, .youApproved, "You approved", others.isEmpty ? "By \(pr.author.name)" : "Also approved by " + others.joined(separator: ", "), nil)
        case .waitingForAuthor:
            set(.waiting, .waitingForAuthor, "Waiting for the author", "You asked \(pr.author.name) for changes", nil)
        case .rejected:
            set(.waiting, .waitingForAuthor, "You rejected it", "By \(pr.author.name)", nil)
        case .none:
            set(.toReview, .reviewPending, mine?.isRequired == true ? "Required review" : "Optional review", "By \(pr.author.name)", nil)
        }
    }

    private static func requirementHeadline(_ requirements: [Check]) -> String {
        guard let first = requirements.first else { return "Waiting" }
        switch first.name {
        case "Comment requirements": return "Resolve comments"
        case "Work item linking": return "Link a work item"
        default: return first.name
        }
    }

    /// The worst state among the required builds and status checks.
    static func checkState(_ checks: [Check]) -> Check.State? {
        let states = checks
            .filter { $0.isBlocking && ($0.kind == .build || $0.kind == .status) && $0.state != .notApplicable }
            .map(\.state)
        for state in [Check.State.failed, .expired, .running, .queued, .pending, .notRun, .passed] where states.contains(state) {
            return state
        }
        return nil
    }
}

public enum PROrdering {
    /// Group order; within a group, the most recent first.
    public static func sorted(_ snapshots: [PRSnapshot]) -> [PRSnapshot] {
        snapshots.sorted { lhs, rhs in
            if lhs.group != rhs.group { return lhs.group < rhs.group }
            let lhsDate = lhs.since ?? .distantPast
            let rhsDate = rhs.since ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.key < rhs.key
        }
    }
}

public struct GroupCounts: Sendable, Equatable, Codable {
    public var needsYou = 0
    public var failing = 0
    public var ready = 0
    public var toReview = 0
    public var waiting = 0
    public var done = 0
    public var idle = 0

    public init() {}

    public init(_ snapshots: [PRSnapshot]) {
        for snapshot in snapshots { self[snapshot.group] += 1 }
    }

    public subscript(group: PRGroup) -> Int {
        get {
            switch group {
            case .needsYou: return needsYou
            case .failing: return failing
            case .ready: return ready
            case .toReview: return toReview
            case .waiting: return waiting
            case .done: return done
            case .idle: return idle
            }
        }
        set {
            switch group {
            case .needsYou: needsYou = newValue
            case .failing: failing = newValue
            case .ready: ready = newValue
            case .toReview: toReview = newValue
            case .waiting: waiting = newValue
            case .done: done = newValue
            case .idle: idle = newValue
            }
        }
    }

    /// Pull requests worth showing (everything except idle).
    public var active: Int { PRGroup.allCases.filter { $0 != .idle }.map { self[$0] }.reduce(0, +) }
}

public enum Elapsed {
    /// Compact relative time: `now`, `3m`, `1h 5m`, `2d`.
    public static func short(since date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        return "\(hours / 24)d"
    }
}
