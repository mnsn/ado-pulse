import ADOPulseCore
import AppKit
import SwiftUI

extension PRGroup {
    var title: String {
        switch self {
        case .needsYou: return "Needs You"
        case .failing: return "Failing"
        case .ready: return "Ready to Complete"
        case .toReview: return "To Review"
        case .waiting: return "Waiting"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    /// For counts: "2 failing", "1 ready to complete".
    var countLabel: String {
        switch self {
        case .needsYou: return "need you"
        case .toReview: return "to review"
        default: return title.lowercased()
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .needsYou: return .systemOrange
        case .failing: return .systemRed
        case .ready: return .systemGreen
        case .toReview: return .systemTeal
        case .waiting: return .systemBlue
        case .done: return .systemPurple
        case .idle: return .secondaryLabelColor
        }
    }

    /// Symbol for count chips in the menu bar, the panel header and the widget.
    var symbol: String {
        switch self {
        case .needsYou: return "hand.raised.fill"
        case .failing: return "xmark.circle.fill"
        case .ready: return "checkmark.circle.fill"
        case .toReview: return "eye.circle.fill"
        case .waiting: return "clock.fill"
        case .done: return "arrow.triangle.merge"
        case .idle: return "moon.zzz.fill"
        }
    }
}

extension PRReason {
    var symbol: String {
        switch self {
        case .mentioned: return "at.circle.fill"
        case .replied: return "arrowshape.turn.up.left.circle.fill"
        case .commented: return "text.bubble.fill"
        case .reviewRequested, .reviewPending: return "eye.circle.fill"
        case .newCommits: return "arrow.triangle.2.circlepath.circle.fill"
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .rejected: return "hand.thumbsdown.circle.fill"
        case .buildFailed: return "xmark.circle.fill"
        case .checkFailed: return "xmark.octagon.fill"
        case .conflicts: return "arrow.triangle.branch"
        case .buildExpired: return "clock.badge.exclamationmark.fill"
        case .readyToComplete: return "checkmark.circle.fill"
        case .autoComplete: return "checkmark.seal.fill"
        case .waitingForReviewers: return "person.2.circle.fill"
        case .checksRunning: return "hourglass.circle.fill"
        case .requirementsPending: return "checklist"
        case .waitingForAuthor: return "clock.circle.fill"
        case .completed: return "arrow.triangle.merge"
        case .abandoned: return "xmark.bin.fill"
        case .draft: return "pencil.circle.fill"
        case .inactive: return "moon.zzz.fill"
        case .youApproved: return "checkmark.circle"
        case .declined: return "person.crop.circle.badge.xmark"
        }
    }

    /// Glyphs without a filled, circled version: rows draw them on a filled circle, like the others.
    var needsBadge: Bool {
        switch self {
        case .conflicts, .requirementsPending, .completed: return true
        default: return false
        }
    }
}

extension PRSnapshot {
    /// Symbol and tint for a row; idle rows are greyed out.
    var rowSymbol: String { reason.symbol }
    var rowColor: Color { group == .idle ? .secondary : group.color }

    var subtitle: String {
        [headline, repository].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
