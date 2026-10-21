import Foundation
import Testing
@testable import ADOPulseCore

/// What needed you and you've answered yourself in Azure DevOps stays in view, in Answered, until you've
/// seen it in the panel or for a day.
@Suite struct AnsweredTests {
    private let me = People.me
    private let cutoff = t(-3 * day)

    private func classify(_ pr: PullRequest, role: PRRole = .reviewer, details: PRDetails?, links: [ChatLink] = [],
                          cutoff: Date? = nil, now: Date = t(0)) -> PRSnapshot? {
        PRClassifier.snapshot(
            for: PRRecord(pullRequest: pr, role: role, details: details, me: me.id, chatLinks: links),
            seenCutoff: cutoff ?? self.cutoff, now: now
        )
    }

    private func sent(_ pr: PullRequest, at date: Date = t(-10 * minute)) -> ChatLink {
        ChatLink(link: PullRequestLink(organization: pr.key.organization, project: pr.projectName, repository: pr.repositoryName,
                                       number: pr.key.number),
                 app: Chats.teams, sender: "Dana Whitfield", sentAt: date, notificationKey: "n1",
                 conversation: Chats.dana, messageID: teamsMessageID(date))
    }

    private func vote(_ thread: Int, _ person: Person, _ vote: Vote, at date: Date) -> Activity {
        Activity(threadId: thread, kind: .vote, at: date, actor: person, vote: vote)
    }

    private func push(_ thread: Int, _ person: Person, at date: Date, commits: Int = 1) -> Activity {
        Activity(threadId: thread, kind: .push, at: date, actor: person, commitCount: commits)
    }

    private func added(_ thread: Int, _ person: Person, by: Person, at date: Date) -> Activity {
        Activity(threadId: thread, kind: .reviewersChanged, at: date, actor: by, added: [person.id])
    }

    @Test func approvingAPullRequestSentToYouKeepsItInView() throws {
        // Like a review assigned to your team: your vote adds you as a reviewer yourself.
        let pr = makePR(author: People.alex, reviewers: [Reviewer(person: me, vote: .approved)])
        let details = makeDetails(for: pr, activity: [added(1, me, by: me, at: t(-5 * minute)), vote(2, me, .approved, at: t(-5 * minute))])
        let snapshot = try #require(classify(pr, details: details, links: [sent(pr)]))
        #expect(snapshot.group == .answered)
        #expect(snapshot.reason == .answered)
        #expect(snapshot.headline == "You approved")
        #expect(snapshot.detail == "Dana Whitfield sent this in Teams")
        #expect(snapshot.since == t(-5 * minute))
        #expect(snapshot.url == pr.webURL)
        #expect(snapshot.chatSource?.sender == "Dana Whitfield")
        #expect(snapshot.pendingEvents.isEmpty)

        // Seen in the panel, up to when you answered: back to Idle.
        let seen = try #require(classify(pr, details: details, links: [sent(pr)], cutoff: t(-5 * minute)))
        #expect(seen.group == .idle)
        #expect(seen.reason == .youApproved)
        // Or never seen, for a day.
        #expect(classify(pr, details: details, links: [sent(pr)], now: t(-5 * minute + day - 1))?.group == .answered)
        #expect(classify(pr, details: details, links: [sent(pr)], now: t(-5 * minute + day))?.group == .idle)
        // A message that had stopped needing you a week after it came isn't answered by a later vote.
        #expect(classify(pr, details: details, links: [sent(pr, at: t(-8 * day))], cutoff: t(-10 * day))?.group == .idle)
    }

    @Test func aCommentAnswersAPullRequestYouAreNotOn() throws {
        let pr = makePR(author: People.alex)
        let thread = ReviewThread(id: 3, comments: [comment(1, me, "Looks good to me", at: t(-5 * minute))])
        let snapshot = try #require(classify(pr, role: .linked, details: makeDetails(for: pr, threads: [thread]), links: [sent(pr)]))
        #expect(snapshot.group == .answered)
        #expect(snapshot.headline == "You commented")
        #expect(snapshot.detail == "Dana Whitfield sent this in Teams")
        // Once seen, it isn't listed: you're not on it.
        #expect(classify(pr, role: .linked, details: makeDetails(for: pr, threads: [thread]), links: [sent(pr)], cutoff: t(-5 * minute)) == nil)
    }

    @Test func repliesAndMentionsYouAnswered() throws {
        let pr = makePR(author: People.sam, reviewers: [Reviewer(person: me, vote: .approved)])
        let reply = ReviewThread(id: 5, comments: [
            comment(1, me, "Why?", at: t(-5 * hour)),
            comment(2, People.sam, "Because", at: t(-hour)),
            comment(3, me, "Fair enough", at: t(-30 * minute)),
        ])
        let replied = try #require(classify(pr, details: makeDetails(for: pr, threads: [reply])))
        #expect(replied.group == .answered)
        #expect(replied.headline == "You replied")
        #expect(replied.detail == "Sam Rivera replied to you")
        #expect(replied.url == pr.threadURL(5))
        #expect(replied.since == t(-30 * minute))

        let mention = ReviewThread(id: 6, comments: [
            comment(1, People.priya, "@Robin Diaz is this right?", at: t(-hour), mentions: [me]),
            comment(2, me, "Yes", at: t(-20 * minute)),
        ])
        let mentioned = try #require(classify(pr, details: makeDetails(for: pr, threads: [reply, mention])))
        // A mention comes first, as in Needs You; the time is your latest answer.
        #expect(mentioned.detail == "Priya Shah mentioned you")
        #expect(mentioned.url == pr.threadURL(6))
        #expect(mentioned.since == t(-20 * minute))

        // Comments between others don't concern you as a reviewer, even once you join in.
        let others = ReviewThread(id: 7, comments: [
            comment(1, People.priya, "Hmm", at: t(-hour)), comment(2, me, "Agreed", at: t(-minute)),
        ])
        #expect(classify(pr, details: makeDetails(for: pr, threads: [others]))?.group == .idle)

        // On your own pull request, any comment needs you, so answering one counts.
        let mine = makePR(reviewers: [Reviewer(person: People.sam, vote: .none)])
        let question = ReviewThread(id: 8, comments: [
            comment(1, People.sam, "Add a test?", at: t(-hour)), comment(2, me, "Added", at: t(-10 * minute)),
        ])
        let answered = try #require(classify(mine, role: .author, details: makeDetails(for: mine, threads: [question])))
        #expect(answered.group == .answered)
        #expect(answered.detail == "Sam Rivera commented")
    }

    @Test func votingOnAReviewRequest() throws {
        let pr = makePR(author: People.sam, reviewers: [Reviewer(person: me, vote: .waitingForAuthor)])
        let activity = [added(1, me, by: People.sam, at: t(-2 * hour)), vote(2, me, .waitingForAuthor, at: t(-hour))]
        let snapshot = try #require(classify(pr, details: makeDetails(for: pr, activity: activity)))
        #expect(snapshot.group == .answered)
        #expect(snapshot.headline == "You asked for changes")
        #expect(snapshot.detail == "Sam Rivera asked you to review")
        // Once seen, it waits for the author.
        #expect(classify(pr, details: makeDetails(for: pr, activity: activity), cutoff: t(-hour))?.group == .waiting)
        // A request you'd already seen waited in To Review: nothing to keep in view.
        #expect(classify(pr, details: makeDetails(for: pr, activity: activity), cutoff: t(-90 * minute))?.group == .waiting)

        // Voting on a pull request you weren't asked to review adds you yourself: there was no request.
        let unasked = makePR(author: People.sam, reviewers: [Reviewer(person: me, vote: .approved)])
        let yourOwn = [added(1, me, by: me, at: t(-hour)), vote(2, me, .approved, at: t(-hour))]
        #expect(classify(unasked, details: makeDetails(for: unasked, activity: yourOwn))?.group == .idle)
    }

    @Test func votingAgainAfterNewCommits() throws {
        let pr = makePR(author: People.sam, created: t(-5 * day), reviewers: [Reviewer(person: me, vote: .approved)])
        let activity = [
            vote(1, me, .waitingForAuthor, at: t(-day)), push(2, People.sam, at: t(-2 * hour), commits: 2), vote(3, me, .approved, at: t(-hour)),
        ]
        let snapshot = try #require(classify(pr, details: makeDetails(for: pr, activity: activity)))
        #expect(snapshot.group == .answered)
        #expect(snapshot.headline == "You approved")
        #expect(snapshot.detail == "New commits by Sam Rivera")
    }

    @Test func pushingTheChangesSomeoneAskedFor() throws {
        let pr = makePR(reviewers: [Reviewer(person: People.sam, vote: .waitingForAuthor)])
        let checks = [Check(name: "CI", kind: .build, state: .passed)]
        let activity = [vote(1, People.sam, .waitingForAuthor, at: t(-2 * hour)), push(2, me, at: t(-hour), commits: 2)]
        let snapshot = try #require(classify(pr, role: .author, details: makeDetails(for: pr, checks: checks, activity: activity)))
        #expect(snapshot.group == .answered)
        #expect(snapshot.headline == "You pushed 2 commits")
        #expect(snapshot.detail == "Sam Rivera asked for changes")

        // Nor one answering a reviewer who has since been removed: that never needed you.
        let removed = makePR(reviewers: [Reviewer(person: People.priya, vote: .none)])
        #expect(classify(removed, role: .author, details: makeDetails(for: removed, checks: checks, activity: activity))?.group == .waiting)

        // Someone else's push isn't your answer.
        let theirs = [vote(1, People.sam, .waitingForAuthor, at: t(-2 * hour)), push(2, People.priya, at: t(-hour))]
        #expect(classify(pr, role: .author, details: makeDetails(for: pr, checks: checks, activity: theirs))?.group == .waiting)
    }

    @Test func somethingElseToDoComesFirst() throws {
        // A failing build on your pull request still shows in Failing.
        let pr = makePR(reviewers: [Reviewer(person: People.sam, vote: .waitingForAuthor)])
        let activity = [vote(1, People.sam, .waitingForAuthor, at: t(-2 * hour)), push(2, me, at: t(-hour))]
        let failing = [Check(name: "CI", kind: .build, state: .failed, completedAt: t(-30 * minute))]
        #expect(classify(pr, role: .author, details: makeDetails(for: pr, checks: failing, activity: activity))?.group == .failing)

        // You answered the message with a comment, but the review is still yours to do; right-click still opens it.
        let review = makePR(author: People.alex, reviewers: [Reviewer(person: me, vote: .none)])
        let thread = ReviewThread(id: 3, comments: [comment(1, me, "After lunch", at: t(-5 * minute))])
        let details = makeDetails(for: review, threads: [thread], activity: [added(1, me, by: People.alex, at: t(-2 * day))])
        let toReview = try #require(classify(review, details: details, links: [sent(review)], cutoff: t(-day)))
        #expect(toReview.group == .toReview)
        #expect(toReview.chatSource?.sender == "Dana Whitfield")

        // Something new that needs you comes before what you answered.
        let again = ReviewThread(id: 4, comments: [comment(1, People.alex, "@Robin Diaz one more thing", at: t(-minute), mentions: [me])])
        let more = makeDetails(for: review, threads: [thread, again], activity: [added(1, me, by: People.alex, at: t(-2 * day))])
        #expect(classify(review, details: more, links: [sent(review)], cutoff: t(-day))?.group == .needsYou)
    }

    @Test func seeingItInThePanelMovesItOnButNotWhatCameAfter() throws {
        let pr = makePR(author: People.sam, reviewers: [Reviewer(person: me, vote: .approved)])
        let thread = ReviewThread(id: 5, comments: [
            comment(1, me, "Why?", at: t(-5 * hour)), comment(2, People.sam, "Because", at: t(-hour)), comment(3, me, "Fair", at: t(-30 * minute)),
        ])
        var seen = SeenState(baseline: cutoff)
        let shown = try #require(classify(pr, details: makeDetails(for: pr, threads: [thread]), cutoff: seen.cutoff(for: pr.key)))
        #expect(shown.group == .answered)

        // Closing the panel marks it seen up to when you answered.
        seen.markSeen([pr.key], at: try #require(shown.since))
        #expect(classify(pr, details: makeDetails(for: pr, threads: [thread]), cutoff: seen.cutoff(for: pr.key))?.group == .idle)

        // A reply after your answer still needs you.
        var later = thread
        later.comments.append(comment(4, People.sam, "Thanks", at: t(-10 * minute)))
        #expect(classify(pr, details: makeDetails(for: pr, threads: [later]), cutoff: seen.cutoff(for: pr.key))?.group == .needsYou)
    }

    @Test func itsNeitherAnnouncedNorSummarized() throws {
        let unvoted = makePR(author: People.alex)
        let before = try #require(classify(unvoted, role: .linked, details: makeDetails(for: unvoted), links: [sent(unvoted)]))
        #expect(before.group == .needsYou)
        let voted = makePR(author: People.alex, reviewers: [Reviewer(person: me, vote: .approved)])
        let details = makeDetails(for: voted, activity: [added(1, me, by: me, at: t(-minute)), vote(2, me, .approved, at: t(-minute))])
        let after = try #require(classify(voted, details: details, links: [sent(voted)]))
        #expect(after.group == .answered)
        #expect(NotificationPlanner.plan(previous: [before], current: [after], notBefore: t(-day)).isEmpty)
        #expect(Brief.items(from: [after]).isEmpty)

        // Nor when your own pull request moves from Needs You to Answered.
        let mine = makePR(reviewers: [Reviewer(person: People.sam, vote: .waitingForAuthor)])
        let asked = [vote(1, People.sam, .waitingForAuthor, at: t(-2 * hour))]
        let needsYou = try #require(classify(mine, role: .author, details: makeDetails(for: mine, activity: asked)))
        let pushed = try #require(classify(mine, role: .author, details: makeDetails(for: mine, activity: asked + [push(2, me, at: t(-minute))])))
        #expect((needsYou.group, pushed.group) == (.needsYou, .answered))
        #expect(NotificationPlanner.plan(previous: [needsYou], current: [pushed], notBefore: t(-day)).isEmpty)
    }
}
