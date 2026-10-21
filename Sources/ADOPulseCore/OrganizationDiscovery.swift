import Foundation

/// Finds the organizations to watch.
public enum OrganizationDiscovery {
    /// Every organization you're a member of.
    public static func memberships(client: ADOClient) async throws -> [String] {
        let profile = try await client.get(ADOEndpoint.profile, as: ADOProfile.self)
        let accounts = try await client.get(ADOEndpoint.accounts(memberId: profile.publicAlias ?? profile.id), as: ADOList<ADOAccount>.self)
        return accounts.value.map(\.accountName).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Your organizations, and the ones to watch.
    public struct Found: Sendable, Equatable {
        public var all: [String]
        /// Where you have an active pull request, as author or reviewer.
        public var withPullRequests: [String]
    }

    /// What probing organizations for your pull requests told.
    public struct Probe: Sendable, Equatable {
        /// Where you have an active pull request, as author or reviewer.
        public var withPullRequests: [String]
        /// Where it couldn't tell: offline, slowed down, or Azure DevOps failing. An organization you can't read
        /// (another tenant, no access) isn't one: there's nothing of yours to show there.
        public var failures: [String: ADOError]
    }

    /// Your organizations and the ones with your pull requests. Throws when it couldn't tell, for example while
    /// offline, rather than finding none, so it can try again.
    public static func discover(client: ADOClient) async throws -> Found {
        let all = try await memberships(client: client)
        let probe = await probe(all, client: client)
        if probe.withPullRequests.isEmpty, let failure = probe.failures.min(by: { $0.key < $1.key }) {
            throw failure.value
        }
        return Found(all: all, withPullRequests: probe.withPullRequests)
    }

    /// Looks for your active pull requests in each organization.
    public static func probe(_ organizations: [String], client: ADOClient, concurrency: Int = 6) async -> Probe {
        var found: [String] = []
        var failures: [String: ADOError] = [:]
        var queue = organizations[...]
        await withTaskGroup(of: (String, Result<Bool, ADOError>).self) { group in
            for _ in 0..<max(1, concurrency) {
                guard let organization = queue.popFirst() else { break }
                group.addTask { (organization, await hasPullRequests(organization, client: client)) }
            }
            while let (organization, result) = await group.next() {
                switch result {
                case .success(let has): if has { found.append(organization) }
                case .failure(let error): failures[organization] = error
                }
                if let next = queue.popFirst() {
                    group.addTask { (next, await hasPullRequests(next, client: client)) }
                }
            }
        }
        return Probe(withPullRequests: organizations.filter(found.contains), failures: failures)
    }

    static func hasPullRequests(_ organization: String, client: ADOClient) async -> Result<Bool, ADOError> {
        do {
            let me = try await client.get(ADOEndpoint.connectionData(organization: organization), as: ADOConnectionData.self)
                .authenticatedUser.id
            for url in [
                ADOEndpoint.pullRequests(organization: organization, creatorId: me, status: "active", top: 1),
                ADOEndpoint.pullRequests(organization: organization, reviewerId: me, status: "active", top: 1),
            ] where !(try await client.get(url, as: ADOList<ADOPullRequest>.self)).value.isEmpty {
                return .success(true)
            }
            return .success(false)
        } catch let error as ADOError {
            switch error {
            // Another tenant, or no access: nothing of yours to show there.
            case .unauthorized, .forbidden, .notFound: return .success(false)
            default: return .failure(error)
            }
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// The union of two lists of organization names, which Azure DevOps compares ignoring case, keeping the
    /// spelling from `preferred`, sorted.
    public static func merged(_ names: [String], preferring preferred: [String]) -> [String] {
        var merged: [String] = []
        for name in preferred + names where !merged.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            merged.append(name)
        }
        return merged.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Organization names are letters, digits and hyphens.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 50 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            && name.first != "-"
    }

    /// The organization in what you typed or pasted: `contoso`, `dev.azure.com/contoso/...`,
    /// `https://contoso.visualstudio.com/...`. Nil if there's none.
    public static func name(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return nil }
        let host = first.lowercased()
        let candidate: String?
        if host == "dev.azure.com" {
            candidate = parts.count > 1 ? parts[1] : nil
        } else if host.hasSuffix(".visualstudio.com") {
            candidate = String(first.dropLast(".visualstudio.com".count))
        } else if parts.count == 1 {
            candidate = first
        } else {
            candidate = nil
        }
        guard let candidate, isValidName(candidate) else { return nil }
        return candidate
    }
}
