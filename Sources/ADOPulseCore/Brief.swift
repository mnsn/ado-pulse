import Foundation

/// The few things at the top of the panel, each as one sentence. The on-device model words the ones with
/// a comment to condense, one at a time; the rest are plain sentences.
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
    /// The on-device model's instructions for brief items.
    public static let instructions = """
        You write one-sentence updates about pull requests for a developer's menu-bar panel. \
        Use plain, friendly English, in at most 22 words. Keep people's names and the pull request title exactly as \
        given. Say what the comment asks for or tells, in your own words. No preamble, no markdown, no emoji. Never \
        add details that aren't in the comment.
        """

    /// The on-device model's instructions for condensing a long comment in a row.
    public static let gistInstructions = """
        You condense code review comments into a short phrase of at most 12 words that says what the comment \
        asks for or tells. No preamble, no quotes, no markdown, no emoji. Never add details that aren't in the comment.
        """

    /// Comments shorter than this are shown as they are.
    public static let gistThreshold = 110

    /// What needs you, then what's failing, then what's ready, newest first.
    public static func items(from snapshots: [PRSnapshot], limit: Int = 3) -> [BriefItem] {
        let picked = PROrdering.sorted(snapshots.filter { [.needsYou, .failing, .ready].contains($0.group) }).prefix(limit)
        return picked.map(item)
    }

    static func item(_ snapshot: PRSnapshot) -> BriefItem {
        let title = "“\(snapshot.title)”"
        let top = snapshot.pendingEvents.first { kindMatches($0.kind, snapshot.reason) } ?? snapshot.pendingEvents.first
        let actor = top?.actor ?? "Someone"
        var sentence: String
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
                    Comment: \(String(text.prefix(1_200)))

                    Write the update.
                    """
            }
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

    /// The prompt that condenses a long comment for its row, or nil when it's short enough already.
    public static func gistPrompt(for text: String) -> String? {
        guard text.count >= gistThreshold else { return nil }
        return "Comment: \(String(text.prefix(1_500)))\n\nWrite the short phrase."
    }

    private static func kindMatches(_ kind: PREvent.Kind, _ reason: PRReason) -> Bool {
        switch (kind, reason) {
        case (.mention, .mentioned), (.reply, .replied), (.comment, .commented): return true
        default: return false
        }
    }
}
