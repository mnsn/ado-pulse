import Foundation

/// Finds the organizations to watch.
public enum OrganizationDiscovery {
    /// Every organization you're a member of.
    public static func memberships(client: ADOClient) async throws -> [String] {
        let profile = try await client.get(ADOEndpoint.profile, as: ADOProfile.self)
        let accounts = try await client.get(ADOEndpoint.accounts(memberId: profile.publicAlias ?? profile.id), as: ADOList<ADOAccount>.self)
        return accounts.value.map(\.accountName).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The organizations where you have an active pull request, as author or reviewer. Organizations that
    /// can't be read (another tenant, no access) are left out.
    public static func withPullRequests(_ organizations: [String], client: ADOClient, concurrency: Int = 6) async -> [String] {
        var found: [String] = []
        var queue = organizations[...]
        await withTaskGroup(of: (String, Bool).self) { group in
            for _ in 0..<max(1, concurrency) {
                guard let organization = queue.popFirst() else { break }
                group.addTask { (organization, await hasPullRequests(organization, client: client)) }
            }
            while let (organization, has) = await group.next() {
                if has { found.append(organization) }
                if let next = queue.popFirst() {
                    group.addTask { (next, await hasPullRequests(next, client: client)) }
                }
            }
        }
        return organizations.filter(found.contains)
    }

    static func hasPullRequests(_ organization: String, client: ADOClient) async -> Bool {
        guard let me = try? await client.get(ADOEndpoint.connectionData(organization: organization), as: ADOConnectionData.self)
            .authenticatedUser.id
        else { return false }
        for url in [
            ADOEndpoint.pullRequests(organization: organization, creatorId: me, status: "active", top: 1),
            ADOEndpoint.pullRequests(organization: organization, reviewerId: me, status: "active", top: 1),
        ] {
            if let list = try? await client.get(url, as: ADOList<ADOPullRequest>.self), !list.value.isEmpty {
                return true
            }
        }
        return false
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
