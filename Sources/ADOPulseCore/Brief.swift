import Foundation

/// The few things at the top of the panel, each as one sentence. The on-device model words the ones with a
/// comment to condense, one item at a time; the rest are plain sentences.
public struct BriefItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var key: PRKey
    public var group: PRGroup
    public var reason: PRReason
    /// Used as is when the on-device model isn't available or fails.
    public var sentence: String
    /// For the on-device model: one item, with the comment it should condense.
    public var prompt: String?
    public var url: URL
}

public enum Brief {
    /// The on-device model's instructions.
    public static let instructions = """
        You turn a code review comment into a one-sentence update for the developer reading it, in the form \
        "<commenter> asks you to ... on <pull request title>" or "<commenter> says ... on <pull request title>". \
        Use the commenter's name exactly as given, put the title in quotes, and say what the comment asks or tells \
        in your own words. Plain English, at most 25 words. No preamble, markdown or emoji. Never add details.
        """

    /// A summary rather than a repeat of the list: the newest of what needs you, what's failing and what's ready,
    /// then more of what needs you.
    public static func items(from snapshots: [PRSnapshot], reader: String? = nil, limit: Int = 3) -> [BriefItem] {
        let groups: [PRGroup] = [.needsYou, .failing, .ready]
        let ordered = PROrdering.sorted(snapshots.filter { groups.contains($0.group) })
        var picked = groups.compactMap { group in ordered.first { $0.group == group } }
        for snapshot in ordered where picked.count < limit && !picked.contains(where: { $0.key == snapshot.key }) {
            picked.append(snapshot)
        }
        return PROrdering.sorted(Array(picked.prefix(limit))).map { item($0, reader: reader) }
    }

    static func item(_ snapshot: PRSnapshot, reader: String?) -> BriefItem {
        let title = "“\(snapshot.title)”"
        let top = snapshot.pendingEvents.first { kindMatches($0.kind, snapshot.reason) } ?? snapshot.pendingEvents.first
        let actor = top?.actor ?? "Someone"
        let sentence: String
        var prompt: String?
        switch snapshot.reason {
        case .mentioned, .replied, .commented:
            let verb = snapshot.reason == .mentioned ? "mentioned you on"
                : snapshot.reason == .replied ? "replied on" : "commented on"
            sentence = "\(actor) \(verb) \(title)."
            if let text = top?.text, !text.isEmpty {
                let relation = snapshot.reason == .mentioned ? "mentioned you"
                    : snapshot.reason == .replied ? "replied to your comment" : "commented on your pull request"
                prompt = """
                    Pull request: \(title)
                    From: \(actor), who \(relation)
                    Comment: \(String(addressingReader(text, reader: reader).prefix(1_200)))

                    Write the update.
                    """
            }
        case .sentInChat:
            let app = top?.app.map { " in \($0)" } ?? ""
            sentence = "\(actor) sent you \(title)\(app)."
        case .reviewRequested: sentence = "\(snapshot.author) asked you to review \(title)."
        case .newCommits: sentence = "\(title) has new commits since your vote."
        case .changesRequested: sentence = "\(actor) is waiting for changes on \(title)."
        case .rejected: sentence = snapshot.group == .needsYou ? "\(actor) rejected \(title)." : "\(title) was rejected."
        case .buildFailed, .checkFailed:
            sentence = "\(title) failed" + (snapshot.detail.map { ": \($0)." } ?? ".")
        case .conflicts: sentence = "\(title) has merge conflicts."
        case .buildExpired: sentence = "\(title) needs its build queued again."
        case .readyToComplete: sentence = "\(title) is approved and ready to complete."
        case .autoComplete: sentence = "\(title) is approved and will complete automatically."
        default: sentence = "\(title): \(snapshot.headline)."
        }
        return BriefItem(
            id: "\(snapshot.id):\(snapshot.reason.rawValue):\(top?.id ?? "")", key: snapshot.key, group: snapshot.group,
            reason: snapshot.reason, sentence: sentence, prompt: prompt, url: snapshot.url
        )
    }

    /// "@Robin Diaz could you…" becomes "you, could you…", so the model writes to you rather than about you.
    static func addressingReader(_ text: String, reader: String?) -> String {
        guard let reader, !reader.isEmpty else { return text }
        return text.replacingOccurrences(of: "@\(reader)", with: "you,")
            .replacingOccurrences(of: "you,,", with: "you,")
    }

    private static func kindMatches(_ kind: PREvent.Kind, _ reason: PRReason) -> Bool {
        switch (kind, reason) {
        case (.mention, .mentioned), (.reply, .replied), (.comment, .commented), (.sentInChat, .sentInChat): return true
        default: return false
        }
    }
}
