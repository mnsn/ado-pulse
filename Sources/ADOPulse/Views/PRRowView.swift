import ADOPulseCore
import SwiftUI

/// One pull request: an icon for why it's here, the title, what's going on and where, a detail such as
/// the comment that needs you, and how long ago it happened.
struct PRRowView: View {
    let item: PRSnapshot
    let now: Date
    var compact = false
    var action: () -> Void

    @LocalState private var isHovered = false

    /// Fixed height of a compact row, so the widget can size itself to a whole number of rows.
    static let compactHeight: CGFloat = 42

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                RowIcon(item: item, size: compact ? 15 : 17)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13, weight: item.group == .idle ? .regular : .semibold))
                            .foregroundStyle(item.group == .idle ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(Elapsed.short(since: item.since, now: now))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if compact {
                        Text(compactLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(item.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(item.rowColor)
                            .lineLimit(1)
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(item.group == .needsYou ? 3 : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 5 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(item.headline)")
        .accessibilityValue([item.repository, item.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens the pull request in Azure DevOps")
    }

    private var compactLine: String {
        guard let detail = item.detail else { return item.subtitle }
        return "\(item.headline) · \(detail)"
    }

    private var helpText: String {
        var lines = [item.title, "\(item.repository) · \(item.project) · !\(item.key.number) by \(item.author)", item.headline]
        if let detail = item.detail { lines.append(detail) }
        if !item.approvals.isEmpty && item.group != .ready { lines.append("Approved by " + item.approvals.joined(separator: ", ")) }
        lines.append("Click to open in Azure DevOps")
        return lines.joined(separator: "\n")
    }
}

/// The row's symbol in its color; outline glyphs sit on a filled circle so every row icon has the same weight.
struct RowIcon: View {
    let item: PRSnapshot
    let size: CGFloat

    var body: some View {
        if item.reason.needsBadge && item.group != .idle {
            ZStack {
                Circle()
                    .fill(item.rowColor)
                Image(systemName: item.rowSymbol)
                    .font(.system(size: size * 0.52, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size * 1.06, height: size * 1.06)
        } else {
            Image(systemName: item.rowSymbol)
                .font(.system(size: size))
                .foregroundStyle(item.rowColor)
        }
    }
}

/// Small "icon count" chips for the non-empty groups.
struct CountChips: View {
    let counts: GroupCounts
    var groups: [PRGroup] = [.needsYou, .failing, .ready, .toReview, .waiting]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(groups, id: \.self) { group in
                if counts[group] > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: group.symbol)
                            .foregroundStyle(group.color)
                        Text("\(counts[group])")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .help("\(counts[group]) \(group.countLabel)")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
