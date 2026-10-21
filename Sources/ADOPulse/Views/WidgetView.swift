import ADOPulseCore
import SwiftUI

/// The desktop widget: pull requests that need attention first, then the most recent idle ones to fill the space.
struct WidgetView: View {
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var settings: AppSettings

    private static let headerHeight: CGFloat = 36
    private static let bottomPadding: CGFloat = 10

    var body: some View {
        let rows = settings.widgetSize.rows
        let active = store.activeItems
        // Reserve the last row for the "+N more" line when everything doesn't fit.
        let visible = active.count > rows ? Array(active.prefix(rows - 1)) : active
        let hidden = active.count - visible.count
        let recent = hidden > 0 ? [] : Array(store.items(in: .idle).prefix(rows - visible.count))

        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .frame(height: Self.headerHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            if visible.isEmpty && recent.isEmpty {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(visible) { row($0) }
                    if hidden > 0 {
                        Text("+\(hidden) more")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 37)
                            .padding(.top, 4)
                    }
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .overlay(alignment: .top) {
                                if index == 0 && !visible.isEmpty {
                                    Rectangle()
                                        .fill(.separator)
                                        .frame(height: 1)
                                        .padding(.horizontal, 8)
                                }
                            }
                    }
                }
                .padding(.horizontal, 6)
                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, Self.bottomPadding)
        .frame(width: settings.widgetSize.width, height: Self.height(for: settings.widgetSize))
        .contextMenu { SettingsMenuContent() }
    }

    private func row(_ item: PRSnapshot) -> some View {
        PRRowView(item: item, now: store.now, compact: true, openSource: item.chatSource == nil ? nil : { store.openSource(item) }) {
            store.open(item)
        }
            .frame(height: PRRowView.compactHeight)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.counts.needsYou > 0 ? Color.orange : Color.accentColor)
            Text("Pull Requests")
                .font(.system(size: 13, weight: .semibold))
            if let problem = store.problem {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(problem.message)
            }
            Spacer()
            if store.hasLoaded && store.counts.active == 0 {
                Text("All clear")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                CountChips(counts: store.counts, groups: settings.widgetSize == .compact ? [.needsYou, .failing, .ready] : [.needsYou, .failing, .ready, .toReview])
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let problem = store.problem {
            VStack(alignment: .leading, spacing: 6) {
                Label(problem.message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if problem.needsSignIn {
                    Button(problem == .cliNotFound ? "Install the Azure CLI…" : "Sign In…") { store.signIn() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
        } else if store.mode == .live && settings.organizations.isEmpty {
            Text(settings.hasDiscovered ? "No organizations to watch" : "Finding your organizations…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if store.hasLoaded {
            QuietView(idleCount: store.counts.idle)
        }
    }

    static func height(for size: AppSettings.WidgetSize) -> CGFloat {
        headerHeight + CGFloat(size.rows) * PRRowView.compactHeight + bottomPadding
    }
}
