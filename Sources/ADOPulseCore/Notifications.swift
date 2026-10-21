import Foundation

/// A notification to post.
public struct PulseNotification: Sendable, Equatable, Identifiable {
    /// Stable, so the same news is never posted twice.
    public var id: String
    public var title: String
    public var subtitle: String?
    public var body: String
    /// What clicking it opens; nil shows the panel.
    public var url: URL?
    /// The pull request it's about, which clicking it marks as seen.
    public var key: PRKey?
    public var at: Date

    public init(id: String, title: String, subtitle: String? = nil, body: String, url: URL?, key: PRKey? = nil, at: Date) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.url = url
        self.key = key
        self.at = at
    }
}

/// Decides what's worth a notification by comparing two consecutive lists: new events (replies,
/// mentions, review requests, votes...), and your pull requests failing, becoming ready or completing.
public enum NotificationPlanner {
    /// `notBefore`: events from before then (usually when ADO Pulse started) are in the panel, not announced.
    public static func plan(previous: [PRSnapshot], current: [PRSnapshot], notBefore: Date, limit: Int = 4) -> [PulseNotification] {
        plan(previous: previous, current: current, notBefore: { _ in notBefore }, limit: limit)
    }

    /// With a time per pull request, such as when its organization was first read.
    public static func plan(
        previous: [PRSnapshot], current: [PRSnapshot], notBefore: (PRSnapshot) -> Date, limit: Int = 4
    ) -> [PulseNotification] {
        let before = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var notes: [PulseNotification] = []
        var earliest = Date.distantFuture
        for snapshot in current {
            let notBefore = notBefore(snapshot)
            earliest = min(earliest, notBefore)
            let old = before[snapshot.key]
            let known = Set(old?.events.map(\.id) ?? [])
            let changedGroup = old.map { $0.hasDetails && $0.group != snapshot.group } ?? false
            let becameReady = changedGroup && snapshot.role == .author && snapshot.group == .ready

            for event in snapshot.events where !known.contains(event.id) && event.at >= notBefore {
                // "Ready to complete" names who approved.
                if event.kind == .approved && becameReady { continue }
                notes.append(note(for: event, in: snapshot))
            }

            guard changedGroup, snapshot.role == .author, snapshot.hasDetails || snapshot.group == .done else { continue }
            let at = max(snapshot.since ?? notBefore, notBefore)
            // When it happened is part of the ID: a build that fails again, or a pull request that's ready again
            // after a push, is news again; a pull request moving back from Needs You in the same state isn't.
            let occurrence = snapshot.since.map { String(Int($0.timeIntervalSince1970)) } ?? ""
            switch snapshot.group {
            case .failing where snapshot.reason != .buildExpired:
                notes.append(PulseNotification(
                    id: "\(snapshot.id):failing:\(snapshot.reason.rawValue):\(occurrence)",
                    title: snapshot.headline, subtitle: snapshot.title, body: snapshot.detail ?? snapshot.repository,
                    url: snapshot.url, key: snapshot.key, at: at
                ))
            case .ready:
                notes.append(PulseNotification(
                    id: "\(snapshot.id):ready:\(occurrence)", title: snapshot.headline, subtitle: snapshot.title,
                    body: snapshot.detail ?? "Every required check passes.", url: snapshot.url, key: snapshot.key, at: at
                ))
            case .done where snapshot.reason == .completed:
                notes.append(PulseNotification(
                    id: "\(snapshot.id):completed", title: "Completed", subtitle: snapshot.title,
                    body: snapshot.detail ?? snapshot.repository, url: snapshot.url, key: snapshot.key, at: at
                ))
            default:
                break
            }
        }

        notes.sort { $0.at > $1.at }
        guard notes.count > limit, limit > 1 else { return notes }
        let shown = Array(notes.prefix(limit - 1))
        let rest = notes.count - shown.count
        return shown + [PulseNotification(
            id: "more:" + notes.dropFirst(shown.count).map(\.id).joined(separator: ","),
            title: "ADO Pulse", body: "\(rest) more pull request updates", url: nil, at: shown.last?.at ?? earliest
        )]
    }

    static func note(for event: PREvent, in snapshot: PRSnapshot) -> PulseNotification {
        let actor = event.actor ?? "Someone"
        let title: String
        var body = event.text
        switch event.kind {
        case .mention: title = "\(actor) mentioned you"
        case .reply: title = "\(actor) replied"
        case .comment: title = "\(actor) commented"
        case .reviewRequest:
            title = "Review requested"
            body = "\(snapshot.author) asked you to review" + (event.text.map { " (\($0.lowercased()))" } ?? "") + "."
        case .newCommits:
            title = "New commits"
            body = (event.count.map { $0 == 1 ? "1 new commit" : "\($0) new commits" } ?? "New commits") + " since your vote."
        case .changesRequested:
            title = "\(actor) is waiting for you"
            body = "They voted \"Waiting for author\"."
        case .rejected:
            title = "\(actor) rejected it"
            body = "They voted \"Rejected\"."
        case .approved:
            title = "\(actor) approved"
            body = snapshot.detail
        }
        return PulseNotification(
            id: "\(snapshot.id):\(event.id)", title: title, subtitle: snapshot.title,
            body: body ?? snapshot.repository, url: snapshot.url, key: snapshot.key, at: event.at
        )
    }
}
