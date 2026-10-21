import Foundation
import Synchronization

/// Why the list may be missing or out of date.
public enum PulseProblem: Sendable, Equatable {
    case noOrganizations
    case cliNotFound
    case signedOut(String)
    case authFailed(String)
    case offline
    case throttled(until: Date)
    /// Nothing could be read; the list shown is the last one that could.
    case unreachable(String)
    /// Some organizations couldn't be read.
    case someOrganizations(String)

    public var message: String {
        switch self {
        case .noOrganizations: return "No Azure DevOps organizations to watch yet."
        case .cliNotFound: return "ADO Pulse signs in with the Azure CLI, which isn't installed."
        case .signedOut: return "Sign in to the Azure CLI to see your pull requests."
        case .authFailed(let message): return "Couldn't get a token from the Azure CLI: \(message)"
        case .offline: return "You're offline. The list may be out of date."
        case .throttled(let until):
            return "Azure DevOps asked ADO Pulse to slow down, until \(until.formatted(date: .omitted, time: .shortened))."
        case .unreachable(let message): return "\(message) The list may be out of date."
        case .someOrganizations(let message): return message
        }
    }

    /// Fixed by signing in (or installing the Azure CLI first).
    public var needsSignIn: Bool {
        switch self {
        case .cliNotFound, .signedOut: return true
        default: return false
        }
    }

    public static func from(_ error: ADOError, organization: String? = nil) -> PulseProblem {
        switch error {
        case .auth(.cliNotFound): return .cliNotFound
        case .auth(.signedOut(let message)): return .signedOut(message)
        case .auth(.failed(let message)): return .authFailed(message)
        case .offline: return .offline
        case .throttled(let seconds): return .throttled(until: Date().addingTimeInterval(seconds))
        case .unauthorized: return .signedOut(error.description)
        default:
            let prefix = organization.map { "Can't read \($0): " } ?? ""
            return .unreachable(prefix + error.description)
        }
    }
}

/// Everything the engine knows at one point in time.
public struct PulseSnapshot: Sendable, Equatable {
    public var records: [PRRecord]
    public var organizations: [String]
    /// Who's signed in to the Azure CLI (`AccessToken.account`), when known: the records are theirs.
    public var account: String?
    /// Your name, as Azure DevOps knows it.
    public var userName: String?
    /// When each organization's lists were first read: what happened there before is in the panel, not news.
    public var firstLoaded: [String: Date]
    public var problem: PulseProblem?
    public var refreshedAt: Date?
    public var isRefreshing: Bool
    public var hasLoaded: Bool

    public init(
        records: [PRRecord] = [], organizations: [String] = [], account: String? = nil, userName: String? = nil,
        firstLoaded: [String: Date] = [:], problem: PulseProblem? = nil, refreshedAt: Date? = nil, isRefreshing: Bool = false,
        hasLoaded: Bool = false
    ) {
        self.records = records
        self.organizations = organizations
        self.account = account
        self.userName = userName
        self.firstLoaded = firstLoaded
        self.problem = problem
        self.refreshedAt = refreshedAt
        self.isRefreshing = isRefreshing
        self.hasLoaded = hasLoaded
    }
}

/// Polls Azure DevOps: the pull request lists every refresh (three requests per organization), and the
/// details of the pull requests the `RefreshPlanner` picks (two requests each). Azure DevOps can't push
/// changes to a personal app, and pull requests and builds take minutes to hours, so a refresh a minute
/// is plenty. Every request is a GET.
public actor PulseEngine {
    public typealias ChangeHandler = @Sendable (PulseSnapshot) -> Void

    public struct Configuration: Sendable, Equatable {
        public var organizations: [String]
        public var interval: TimeInterval
        /// Completed pull requests from this far back are listed (as Done).
        public var keepDoneFor: TimeInterval
        /// Drafts and pull requests idle for this long have their details refreshed less often.
        public var inactiveAfter: TimeInterval?
        public var planner: RefreshPlanner.Options
        /// Pull requests whose details are fetched at the same time.
        public var concurrency: Int

        public init(
            organizations: [String], interval: TimeInterval = 60, keepDoneFor: TimeInterval = 86_400,
            inactiveAfter: TimeInterval? = 14 * 86_400, planner: RefreshPlanner.Options = RefreshPlanner.Options(),
            concurrency: Int = 4
        ) {
            self.organizations = organizations
            self.interval = interval
            self.keepDoneFor = keepDoneFor
            self.inactiveAfter = inactiveAfter
            self.planner = planner
            self.concurrency = concurrency
        }
    }

    private struct Listed: Sendable {
        var pullRequest: PullRequest
        var role: PRRole
    }

    /// One read of a pull request's details. Its policies and its threads are read separately, and either can fail
    /// while the other doesn't.
    private struct DetailsRead: Sendable {
        /// The policies, nil when the project doesn't let you read them; or what went wrong reading them.
        var policies: Result<[ADOPolicyEvaluation]?, ADOError>
        var threads: Result<[ADOThread], ADOError>

        var errors: [ADOError] {
            var errors: [ADOError] = []
            if case .failure(let error) = policies { errors.append(error) }
            if case .failure(let error) = threads { errors.append(error) }
            return errors
        }
    }

    /// One of your pull requests that left the active list without showing up as completed.
    private struct Vanished: Sendable {
        var pullRequest: PullRequest
        /// When it left the list.
        var since: Date
        /// When it was last looked up, and how many lookups in a row failed.
        var lastLookup: Date?
        var failures = 0

        /// Whether to look it up on a refresh at `date`: right away, again on the next refresh if that fails, then
        /// less and less often, so the ones that keep failing don't cost requests every refresh.
        func isDue(at date: Date, interval: TimeInterval) -> Bool {
            guard let lastLookup, failures > 1 else { return true }
            return date.timeIntervalSince(lastLookup) >= min(interval * pow(2, Double(failures - 2)), 1_800)
        }
    }

    private struct OrganizationLists: Sendable {
        var me: String
        var name: String?
        var mine: [PullRequest]
        var reviewing: [PullRequest]
        var completed: [PullRequest]
    }

    private let client: ADOClient
    private var configuration: Configuration
    private let onChange: ChangeHandler
    private let now: @Sendable () -> Date
    private let waker = Waker()
    private var loop: Task<Void, Never>?

    /// Organization → your identity ID there.
    private var identities: [String: String] = [:]
    /// Whose sign-in the identities, lists and details are for.
    private var account: String?
    private var userName: String?
    private var firstLoaded: [String: Date] = [:]
    private var active: [PRKey: Listed] = [:]
    private var done: [PRKey: PullRequest] = [:]
    private var details: [PRKey: PRDetails] = [:]
    private var entries: [PRKey: RefreshPlanner.Entry] = [:]
    /// Your pull requests that left the active list without completing: abandoned, or completed just now. Each
    /// is looked up by its ID, a few per refresh, until that works or it's too old to show as done.
    private var vanished: [PRKey: Vanished] = [:]
    private var problem: PulseProblem?
    private var refreshedAt: Date?
    private var hasLoaded = false
    private var isRefreshing = false
    /// Refreshes in a row that read nothing, for backing off.
    private var failures = 0
    private var lastPublished: PulseSnapshot?

    public init(
        client: ADOClient, configuration: Configuration, now: @escaping @Sendable () -> Date = { Date() },
        onChange: @escaping ChangeHandler
    ) {
        self.client = client
        self.configuration = configuration
        self.now = now
        self.onChange = onChange
    }

    /// Refreshes now and then on every interval, until stopped.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNow()
                let delay = await self.nextDelay()
                await self.waker.wait(for: delay)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        waker.wake()
    }

    /// Asks for a refresh as soon as possible, for example when the panel opens or the Mac wakes.
    public nonisolated func refresh() {
        waker.wake()
    }

    public func setConfiguration(_ configuration: Configuration) {
        guard configuration != self.configuration else { return }
        let organizationsChanged = configuration.organizations != self.configuration.organizations
        self.configuration = configuration
        if organizationsChanged {
            let kept = Set(configuration.organizations)
            active = active.filter { kept.contains($0.key.organization) }
            done = done.filter { kept.contains($0.key.organization) }
            vanished = vanished.filter { kept.contains($0.key.organization) }
            firstLoaded = firstLoaded.filter { kept.contains($0.key) }
            publish()
        }
        waker.wake()
    }

    /// One load, without the timer: for the command line and tests.
    public static func loadOnce(client: ADOClient, configuration: Configuration) async -> PulseSnapshot {
        let engine = PulseEngine(client: client, configuration: configuration) { _ in }
        await engine.refreshNow()
        return await engine.currentSnapshot()
    }

    public func currentSnapshot() -> PulseSnapshot {
        snapshot()
    }

    /// One refresh: the lists, then the details the planner picks.
    public func refreshNow() async {
        let configuration = self.configuration
        let organizations = configuration.organizations
        guard !organizations.isEmpty else {
            problem = .noOrganizations
            hasLoaded = true
            publish()
            return
        }
        isRefreshing = true
        publish()
        defer {
            isRefreshing = false
            hasLoaded = true
            publish()
        }

        // Signing in comes first: nothing works without a token, and a failure here says exactly what's wrong.
        let token: AccessToken
        do {
            token = try await client.tokens.token()
        } catch {
            problem = PulseProblem.from((error as? AuthError).map(ADOError.auth) ?? .auth(.failed(String(describing: error))))
            failures += 1
            return
        }
        // Someone else signed in: your identity in each organization, and everything read as the last one, is out
        // of date.
        if let signedIn = token.account {
            if let account, account != signedIn { forgetAccount() }
            account = signedIn
        }

        let startedAt = now()
        let closedSince = startedAt.addingTimeInterval(-configuration.keepDoneFor)
        let client = self.client
        let known = identities
        var results: [String: Result<OrganizationLists, ADOError>] = [:]
        await withTaskGroup(of: (String, Result<OrganizationLists, ADOError>).self) { group in
            for organization in organizations {
                group.addTask {
                    (organization, await Self.lists(organization, me: known[organization], client: client, closedSince: closedSince))
                }
            }
            for await (organization, result) in group {
                results[organization] = result
            }
        }

        var listed: [PRKey: Listed] = [:]
        var completed: [PRKey: PullRequest] = [:]
        var errors: [(String, ADOError)] = []
        for organization in organizations {
            switch results[organization] {
            case .success(let lists):
                identities[organization] = lists.me
                if let name = lists.name { userName = name }
                if firstLoaded[organization] == nil { firstLoaded[organization] = startedAt }
                for pr in lists.mine where pr.status == .active {
                    listed[pr.key] = Listed(pullRequest: pr, role: .author)
                }
                for pr in lists.reviewing where pr.status == .active && pr.author.id != lists.me && listed[pr.key] == nil {
                    listed[pr.key] = Listed(pullRequest: pr, role: .reviewer)
                }
                for pr in lists.completed {
                    completed[pr.key] = pr
                }
            case .failure(let error):
                errors.append((organization, error))
                // Keep what we had until it can be read again.
                for (key, item) in active where key.organization == organization { listed[key] = item }
                for (key, pr) in done where key.organization == organization { completed[key] = pr }
            case nil:
                break
            }
        }

        if errors.count == organizations.count, let (organization, error) = errors.first {
            problem = PulseProblem.from(error, organization: organizations.count > 1 ? organization : nil)
            failures += 1
            return
        }
        failures = 0

        // Your pull requests that left the active list without completing were abandoned (or completed
        // just now): look each up by its ID, a few per refresh, and again next time if that fails.
        let succeeded = Set(organizations).subtracting(errors.map(\.0))
        for item in active.values where item.role == .author && succeeded.contains(item.pullRequest.key.organization) {
            let key = item.pullRequest.key
            if listed[key] == nil, completed[key] == nil, vanished[key] == nil {
                vanished[key] = Vanished(pullRequest: item.pullRequest, since: startedAt)
            }
        }
        // Back in the list, listed as completed, or gone longer than Done shows anything.
        vanished = vanished.filter { key, item in listed[key] == nil && completed[key] == nil && item.since > closedSince }
        // The ones never looked up first, then the ones looked up longest ago: a few that keep failing don't hold up
        // the rest.
        let due = vanished.values
            .filter { succeeded.contains($0.pullRequest.key.organization) && $0.isDue(at: startedAt, interval: configuration.interval) }
            .sorted {
                ($0.lastLookup ?? .distantPast, $0.since, $0.pullRequest.key) < ($1.lastLookup ?? .distantPast, $1.since, $1.pullRequest.key)
            }
            .prefix(5)
        for item in due {
            let key = item.pullRequest.key
            do {
                let dto = try await client.get(ADOEndpoint.pullRequest(organization: key.organization, id: key.number), as: ADOPullRequest.self)
                let fresh = PullRequest(organization: key.organization, dto)
                if fresh.status == .completed || fresh.status == .abandoned { completed[key] = fresh }
                vanished[key] = nil
            } catch ADOError.notFound, ADOError.forbidden {
                // Deleted, or moved somewhere you can't read: nothing to show.
                vanished[key] = nil
            } catch ADOError.throttled {
                break
            } catch {
                vanished[key]?.lastLookup = startedAt
                vanished[key]?.failures += 1
            }
        }
        for (key, pr) in done where completed[key] == nil && listed[key] == nil {
            completed[key] = pr
        }
        // The organizations may have changed while the lists loaded: keep only the ones still watched.
        let watched = Set(self.configuration.organizations)
        listed = listed.filter { watched.contains($0.key.organization) }
        completed = completed.filter { watched.contains($0.key.organization) }
        vanished = vanished.filter { watched.contains($0.key.organization) }
        firstLoaded = firstLoaded.filter { watched.contains($0.key) }
        active = listed
        done = completed.filter { listed[$0.key] == nil && ($0.value.closedAt ?? .distantPast) > closedSince }
        details = details.filter { listed[$0.key] != nil }
        entries = entries.filter { listed[$0.key] != nil }

        // Details for every pull request without them (all of them on the first load), and a budget of others.
        let candidates = listed.values.map {
            RefreshPlanner.Candidate(key: $0.pullRequest.key, fingerprint: $0.pullRequest.fingerprint)
        }
        let keys = RefreshPlanner.plan(
            candidates, cache: entries, now: startedAt, options: configuration.planner, limit: configuration.planner.budget
        )
        let throttled = await fetchDetails(keys.compactMap { listed[$0]?.pullRequest }, configuration: configuration)

        refreshedAt = now()
        if let throttled {
            problem = PulseProblem.from(throttled)
        } else if !errors.isEmpty {
            let names = errors.map { "\($0.0) (\($0.1.description))" }.joined(separator: ", ")
            problem = .someOrganizations("Couldn't read \(names).")
        } else {
            problem = nil
        }
    }

    private func forgetAccount() {
        identities = [:]
        userName = nil
        firstLoaded = [:]
        active = [:]
        done = [:]
        details = [:]
        entries = [:]
        vanished = [:]
    }

    /// Fetches details a few pull requests at a time. Returns the error if Azure DevOps asked to slow down.
    private func fetchDetails(_ pullRequests: [PullRequest], configuration: Configuration) async -> ADOError? {
        guard !pullRequests.isEmpty else { return nil }
        let client = self.client
        let fetchedAt = now()
        var queue = pullRequests[...]
        var throttled: ADOError?
        await withTaskGroup(of: (PullRequest, DetailsRead).self) { group in
            for _ in 0..<max(1, configuration.concurrency) {
                guard let pr = queue.popFirst() else { break }
                group.addTask { (pr, await Self.details(of: pr, client: client)) }
            }
            while let (pr, read) = await group.next() {
                switch (read.policies, read.threads) {
                case (.success(let policies), .success(let threads)):
                    let fetched = PRDetails(fetchedAt: fetchedAt, pullRequest: pr, evaluations: policies, threads: threads)
                    details[pr.key] = fetched
                    entries[pr.key] = RefreshPlanner.Entry(
                        fetchedAt: fetchedAt, fingerprint: pr.fingerprint, isBusy: fetched.hasChecksInProgress,
                        isQuiet: isQuiet(pr, fetched, configuration: configuration, at: fetchedAt)
                    )
                default:
                    // Keep the old details, and try again on the normal schedule rather than every refresh. But what
                    // the policies say now replaces what they said, even when the threads couldn't be read: a pull
                    // request whose policies you may no longer read, or whose build failed since, isn't ready.
                    if case .success(let policies) = read.policies, var kept = details[pr.key] {
                        kept.checks = policies?.compactMap(Check.init) ?? []
                        kept.checksKnown = policies != nil
                        details[pr.key] = kept
                    }
                    entries[pr.key] = RefreshPlanner.Entry(
                        fetchedAt: fetchedAt, fingerprint: pr.fingerprint, isBusy: details[pr.key]?.hasChecksInProgress ?? false,
                        isQuiet: details[pr.key].map { isQuiet(pr, $0, configuration: configuration, at: fetchedAt) } ?? false
                    )
                    if let error = read.errors.first(where: { if case .throttled = $0 { true } else { false } }) {
                        throttled = error
                        queue.removeAll()
                    }
                }
                if let next = queue.popFirst() {
                    group.addTask { (next, await Self.details(of: next, client: client)) }
                }
            }
        }
        return throttled
    }

    private func isQuiet(_ pr: PullRequest, _ details: PRDetails, configuration: Configuration, at date: Date) -> Bool {
        if pr.isDraft { return true }
        guard let inactiveAfter = configuration.inactiveAfter, let last = details.lastActivity else { return false }
        return date.timeIntervalSince(max(last, pr.createdAt)) > inactiveAfter
    }

    private static func lists(
        _ organization: String, me known: String?, client: ADOClient, closedSince: Date
    ) async -> Result<OrganizationLists, ADOError> {
        do {
            let me: String
            var name: String?
            if let known {
                me = known
            } else {
                let user = try await client.get(ADOEndpoint.connectionData(organization: organization), as: ADOConnectionData.self)
                    .authenticatedUser
                me = user.id.lowercased()
                name = user.providerDisplayName
            }
            typealias List = ADOList<ADOPullRequest>
            async let mine = client.get(ADOEndpoint.pullRequests(organization: organization, creatorId: me, status: "active"), as: List.self)
            async let reviewing = client.get(
                ADOEndpoint.pullRequests(organization: organization, reviewerId: me, status: "active"), as: List.self)
            async let completed = client.get(ADOEndpoint.pullRequests(
                organization: organization, creatorId: me, status: "completed", closedSince: closedSince, top: 50
            ), as: List.self)
            let (m, r, c) = try await (mine, reviewing, completed)
            func convert(_ list: List) -> [PullRequest] { list.value.map { PullRequest(organization: organization, $0) } }
            return .success(OrganizationLists(me: me, name: name, mine: convert(m), reviewing: convert(r), completed: convert(c)))
        } catch let error as ADOError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private static func details(of pr: PullRequest, client: ADOClient) async -> DetailsRead {
        let organization = pr.key.organization
        async let evaluations = capture {
            try await client.get(ADOEndpoint.policyEvaluations(
                organization: organization, projectId: pr.projectId, pullRequestId: pr.key.number
            ), as: ADOList<ADOPolicyEvaluation>.self).value
        }
        async let threads = capture {
            try await client.get(ADOEndpoint.threads(
                organization: organization, projectId: pr.projectId, repositoryId: pr.repositoryId, pullRequestId: pr.key.number
            ), as: ADOList<ADOThread>.self).value
        }
        let (policyResult, threadResult) = await (evaluations, threads)
        let policies: Result<[ADOPolicyEvaluation]?, ADOError>
        switch policyResult {
        case .success(let value): policies = .success(value)
        // Some projects don't let everyone read their policies. The pull request still has its threads, but
        // whether it's ready is unknown, which isn't the same as having no policies.
        case .failure(.forbidden), .failure(.notFound): policies = .success(nil)
        case .failure(let error): policies = .failure(error)
        }
        return DetailsRead(policies: policies, threads: threadResult)
    }

    private static func capture<T: Sendable>(_ body: () async throws -> T) async -> Result<T, ADOError> {
        do {
            return .success(try await body())
        } catch let error as ADOError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private func nextDelay() -> TimeInterval {
        let interval = configuration.interval
        switch problem {
        case .throttled(let until)?:
            return max(until.timeIntervalSince(now()), interval)
        case .cliNotFound?, .signedOut?, .authFailed?:
            // Pick up an `az login` within a minute; asking the CLI costs nothing on the network.
            return min(interval, 60)
        default:
            guard failures > 0 else { return interval }
            return min(interval * pow(2, Double(min(failures, 4))), 600)
        }
    }

    private func snapshot() -> PulseSnapshot {
        var records = active.map { key, item in
            PRRecord(pullRequest: item.pullRequest, role: item.role, details: details[key], me: identities[key.organization] ?? "")
        }
        records += done.map { key, pr in
            PRRecord(pullRequest: pr, role: .author, me: identities[key.organization] ?? "")
        }
        records.sort { $0.id < $1.id }
        return PulseSnapshot(
            records: records, organizations: configuration.organizations, account: account, userName: userName, firstLoaded: firstLoaded,
            problem: problem, refreshedAt: refreshedAt, isRefreshing: isRefreshing, hasLoaded: hasLoaded
        )
    }

    private func publish() {
        let current = snapshot()
        guard current != lastPublished else { return }
        lastPublished = current
        onChange(current)
    }
}

/// Lets the refresh loop sleep until its next refresh, or until something asks for one sooner.
final class Waker: Sendable {
    private struct State {
        var pending = false
        var continuation: CheckedContinuation<Void, Never>?
        var generation = 0
    }

    private let state = Mutex(State())

    func wake() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let continuation = state.continuation else {
                state.pending = true
                return nil
            }
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    /// Returns after `seconds`, or as soon as `wake()` is called (including before this was).
    func wait(for seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let generation = state.withLock { state -> Int? in
                if state.pending {
                    state.pending = false
                    return nil
                }
                state.generation += 1
                state.continuation = continuation
                return state.generation
            }
            guard let generation else {
                continuation.resume()
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, seconds)))
                self?.expire(generation)
            }
        }
    }

    private func expire(_ generation: Int) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard state.generation == generation, let continuation = state.continuation else { return nil }
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}
