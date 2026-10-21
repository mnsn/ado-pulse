import ADOPulseCore
import SwiftUI

/// The menu-bar popover: every pull request grouped by what it needs from you.
struct MenuPanelView: View {
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var loginItem: LoginItem

    @LocalState private var contentHeight: CGFloat = 0
    @LocalState private var showIdle = false

    private static let maxListHeight: CGFloat = 560
    private static let shownGroups: [PRGroup] = [.needsYou, .answered, .failing, .ready, .toReview, .waiting, .done]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                list
                    .padding(8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 60), Self.maxListHeight))
            Divider()
            footer
        }
        .frame(width: 400)
        .onAppear { loginItem.refresh() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.pull")
                .foregroundStyle(.tint)
            Text("ADO Pulse")
                .font(.headline)
            Spacer()
            CountChips(counts: store.counts)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let problem = store.problem {
                ProblemView(problem: problem) { store.signIn() }
            }

            if settings.chatLinksEnabled && store.chatAccess == .denied {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane")
                        .foregroundStyle(.secondary)
                    Text("Pull requests sent in chats need Full Disk Access.")
                        .foregroundStyle(.secondary)
                    Button("Set Up…") { store.showChatAccessSetup?() }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
            } else if settings.chatLinksEnabled, let problem = store.chatProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.notifications && store.notificationsBlocked {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.secondary)
                    Text("Notifications are off for ADO Pulse.")
                        .foregroundStyle(.secondary)
                    Button("Turn On…") { Notifier.openSystemSettings() }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .help("Allow notifications for ADO Pulse in System Settings › Notifications, or turn Notifications off in its settings")
            }

            // Without organizations to watch, pull requests people sent you may still be listed.
            if store.mode == .live && settings.organizations.isEmpty && store.items.isEmpty {
                OrganizationsPlaceholder()
            } else if store.isLoading && store.problem == nil {
                VStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading your pull requests…")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else if store.hasLoaded && store.activeItems.isEmpty && store.problem == nil {
                QuietView(idleCount: store.counts.idle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }

            if store.showsBrief {
                BriefView()
            }

            ForEach(Self.shownGroups, id: \.self) { group in
                let items = store.items(in: group)
                if !items.isEmpty {
                    section(group, items)
                }
            }

            let idle = store.items(in: .idle)
            if !idle.isEmpty {
                DisclosureGroup(isExpanded: $showIdle) {
                    VStack(spacing: 0) {
                        ForEach(idle) { item in
                            PRRowView(item: item, now: store.now, compact: true, openSource: source(item)) { store.open(item) }
                        }
                    }
                } label: {
                    Text("Idle (\(idle.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showIdle.toggle() } }
                }
                .padding(.horizontal, 8)
                .help("Drafts, pull requests without recent activity, and reviews you've approved or declined")
            }
        }
    }

    private func section(_ group: PRGroup, _ items: [PRSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(group.title) (\(items.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(group.color)
                    .help(group == .answered ? "You took care of these in Azure DevOps. Once you've seen them here, they go back to their usual group." : "")
                Spacer()
                if group == .needsYou || group == .done {
                    Button(group == .needsYou ? "Mark as Seen" : "Clear") { store.clear(group) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .help(group == .needsYou ? "You've seen these: move them to their usual group" : "Remove these from the list")
                }
            }
            .padding(.horizontal, 8)
            ForEach(items) { item in
                PRRowView(item: item, now: store.now, openSource: source(item)) { store.open(item) }
            }
        }
    }

    /// Opens the message a pull request was sent in, when it was.
    private func source(_ item: PRSnapshot) -> (() -> Void)? {
        item.chatSource == nil ? nil : { store.openSource(item) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                store.openPullRequestsPage()
            } label: {
                Label("Open Azure DevOps", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            Spacer()
            RefreshStatus()
            Menu {
                SettingsMenuContent()
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// "Updated 2m ago", a spinner while refreshing, and a button to refresh now.
struct RefreshStatus: View {
    @EnvironmentObject private var store: PRStore

    var body: some View {
        HStack(spacing: 6) {
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            } else if let refreshedAt = store.refreshedAt, store.mode == .live {
                Text(Elapsed.short(since: refreshedAt, now: store.now) == "now" ? "Updated now" : "Updated \(Elapsed.short(since: refreshedAt, now: store.now)) ago")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
            }
            if store.mode == .live {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
                .help("Refresh now")
            }
        }
    }
}

/// A few lines at the top, worded on this Mac by Apple Intelligence: what needs you, what failed, what's ready.
struct BriefView: View {
    @EnvironmentObject private var store: PRStore

    private static let gradient = LinearGradient(
        colors: [Color(red: 0.98, green: 0.55, blue: 0.20), Color(red: 0.93, green: 0.30, blue: 0.55),
                 Color(red: 0.55, green: 0.35, blue: 0.95), Color(red: 0.25, green: 0.55, blue: 1.0)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.gradient)
                Text("Brief")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(store.brief) { item in
                Button {
                    if let snapshot = store.items.first(where: { $0.key == item.key }) { store.open(snapshot) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(item.group.color)
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                        Text(store.briefText(item))
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to open in Azure DevOps")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Self.gradient.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Self.gradient.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 4)
        .help("Summarized on this Mac by Apple Intelligence")
    }
}

/// Why the list is missing or may be out of date, with a way to sign in when that's the reason.
struct ProblemView: View {
    let problem: PulseProblem
    var signIn: () -> Void

    var body: some View {
        if problem.needsSignIn {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(problem.message)
                        .font(.system(size: 12, weight: .semibold))
                } icon: {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(problem == .cliNotFound ? "Install the Azure CLI…" : "Sign In…", action: signIn)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
            .padding(.horizontal, 4)
        } else {
            Label(problem.message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: String {
        if problem == .cliNotFound {
            return "Install it with Homebrew (brew install azure-cli), then sign in once. No personal access token needed."
        }
        return "ADO Pulse uses the Azure CLI's sign-in, so there's no token to create. Sign In opens Terminal to run "
            + "az login in your browser; it stays signed in after that."
    }
}

/// Before there are organizations to watch: finding them, or choosing them.
struct OrganizationsPlaceholder: View {
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 6) {
            if store.discovery == .running || !settings.hasDiscovered && store.problem == nil {
                ProgressView()
                    .controlSize(.small)
                Text("Finding your Azure DevOps organizations…")
                    .font(.system(size: 13, weight: .semibold))
                Text("Once, the first time: it looks for the ones where you have pull requests.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if settings.hasDiscovered {
                Image(systemName: "building.2")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text("No organizations to watch")
                    .font(.system(size: 13, weight: .semibold))
                Text("None of your organizations has an active pull request of yours or for you to review.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Menu("Choose Organizations") {
                    OrganizationsMenuContent()
                }
                .fixedSize()
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
    }
}

struct QuietView: View {
    let idleCount: Int

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("All clear")
                .font(.system(size: 13, weight: .semibold))
            Text(idleCount == 0 ? "No open pull requests" : idleCount == 1 ? "1 idle pull request" : "\(idleCount) idle pull requests")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
