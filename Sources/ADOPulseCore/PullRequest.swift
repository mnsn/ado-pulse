import Foundation

/// Identifies a pull request: its number is unique within its organization.
public struct PRKey: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var organization: String
    public var number: Int

    public init(_ organization: String, _ number: Int) {
        self.organization = organization
        self.number = number
    }

    public var description: String { "\(organization)/\(number)" }

    public static func < (lhs: PRKey, rhs: PRKey) -> Bool {
        (lhs.organization, lhs.number) < (rhs.organization, rhs.number)
    }
}

/// Whether you wrote the pull request, were asked to review it, or someone sent you a link to it.
public enum PRRole: String, Sendable, Codable {
    case author, reviewer
    /// You're neither its author nor a reviewer: someone sent it to you in a chat.
    case linked
}

public enum Vote: Int, Sendable, Codable, CaseIterable {
    case rejected = -10
    case waitingForAuthor = -5
    case none = 0
    case approvedWithSuggestions = 5
    case approved = 10

    public init(_ raw: Int?) {
        self = raw.flatMap(Vote.init(rawValue:)) ?? .none
    }

    public init(_ raw: String?) {
        self.init(raw.flatMap { Int($0) })
    }

    public var isApproval: Bool { self == .approved || self == .approvedWithSuggestions }
    /// Waiting for the author or rejected: the reviewer wants changes.
    public var wantsChanges: Bool { self == .waitingForAuthor || self == .rejected }
}

public struct Person: Sendable, Codable, Hashable {
    /// Lowercased, so IDs from different endpoints compare equal.
    public var id: String
    public var name: String
    /// A service identity, such as a build service or a bot, rather than a person.
    public var isBot: Bool

    public init(id: String, name: String, isBot: Bool = false) {
        self.id = id.lowercased()
        self.name = name
        self.isBot = isBot
    }

    init(_ identity: ADOIdentity) {
        self.init(id: identity.id, name: identity.displayName ?? "Someone", isBot: Person.isService(identity))
    }

    /// People sign in with an email-style name; build services and bots don't have one.
    static func isService(_ identity: ADOIdentity) -> Bool {
        if identity.isContainer == true { return true }
        if let unique = identity.uniqueName, !unique.isEmpty, !unique.contains("@") { return true }
        let name = (identity.displayName ?? "").lowercased()
        return name.hasSuffix(" bot") || name.hasSuffix("[bot]") || name.contains("build service")
    }

    /// "Sam" from "Sam Rivera", for compact lines.
    public var firstName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Names like "Rivera, Sam" put the first name last.
        if let comma = trimmed.firstIndex(of: ",") {
            let rest = trimmed[trimmed.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if let first = rest.split(separator: " ").first { return String(first) }
        }
        return trimmed.split(separator: " ").first.map(String.init) ?? trimmed
    }
}

public struct Reviewer: Sendable, Codable, Hashable {
    public var person: Person
    public var vote: Vote
    public var isRequired: Bool
    /// A team or group rather than a person.
    public var isGroup: Bool
    public var hasDeclined: Bool

    public init(person: Person, vote: Vote, isRequired: Bool = false, isGroup: Bool = false, hasDeclined: Bool = false) {
        self.person = person
        self.vote = vote
        self.isRequired = isRequired
        self.isGroup = isGroup
        self.hasDeclined = hasDeclined
    }
}

public struct PullRequest: Sendable, Codable, Equatable, Identifiable {
    public enum Status: String, Sendable, Codable {
        case active, completed, abandoned, other
    }

    public var key: PRKey
    public var title: String
    public var status: Status
    public var author: Person
    public var createdAt: Date
    public var closedAt: Date?
    public var projectId: String
    public var projectName: String
    public var repositoryId: String
    public var repositoryName: String
    public var sourceBranch: String
    public var targetBranch: String
    public var isDraft: Bool
    public var mergeStatus: String?
    public var reviewers: [Reviewer]
    public var autoComplete: Bool
    public var sourceCommit: String?
    public var targetCommit: String?

    public var id: PRKey { key }

    public init(
        key: PRKey, title: String, status: Status = .active, author: Person, createdAt: Date, closedAt: Date? = nil,
        projectId: String, projectName: String, repositoryId: String, repositoryName: String,
        sourceBranch: String = "feature", targetBranch: String = "main", isDraft: Bool = false, mergeStatus: String? = "succeeded",
        reviewers: [Reviewer] = [], autoComplete: Bool = false, sourceCommit: String? = nil, targetCommit: String? = nil
    ) {
        self.key = key
        self.title = title
        self.status = status
        self.author = author
        self.createdAt = createdAt
        self.closedAt = closedAt
        self.projectId = projectId
        self.projectName = projectName
        self.repositoryId = repositoryId
        self.repositoryName = repositoryName
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.isDraft = isDraft
        self.mergeStatus = mergeStatus
        self.reviewers = reviewers
        self.autoComplete = autoComplete
        self.sourceCommit = sourceCommit
        self.targetCommit = targetCommit
    }

    public init(organization: String, _ dto: ADOPullRequest) {
        self.init(
            key: PRKey(organization, dto.pullRequestId),
            title: PlainText.singleLine(dto.title),
            status: Status(rawValue: dto.status) ?? .other,
            author: Person(dto.createdBy),
            createdAt: dto.creationDate,
            closedAt: dto.closedDate,
            projectId: dto.repository.project.id,
            projectName: dto.repository.project.name,
            repositoryId: dto.repository.id,
            repositoryName: dto.repository.name,
            sourceBranch: Self.branchName(dto.sourceRefName),
            targetBranch: Self.branchName(dto.targetRefName),
            isDraft: dto.isDraft ?? false,
            mergeStatus: dto.mergeStatus,
            reviewers: (dto.reviewers ?? []).map { reviewer in
                Reviewer(
                    person: Person(ADOIdentity(id: reviewer.id, displayName: reviewer.displayName,
                                               uniqueName: reviewer.uniqueName, isContainer: reviewer.isContainer)),
                    vote: Vote(reviewer.vote),
                    isRequired: reviewer.isRequired ?? false,
                    isGroup: reviewer.isContainer ?? false,
                    hasDeclined: reviewer.hasDeclined ?? false
                )
            },
            autoComplete: dto.autoCompleteSetBy != nil,
            sourceCommit: dto.lastMergeSourceCommit?.commitId,
            targetCommit: dto.lastMergeTargetCommit?.commitId
        )
    }

    static func branchName(_ ref: String?) -> String {
        guard let ref else { return "" }
        return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    public var hasConflicts: Bool { mergeStatus == "conflicts" }

    public var webURL: URL {
        ADOEndpoint.pullRequestPage(organization: key.organization, project: projectName, repository: repositoryName, id: key.number)
    }

    /// Opens the pull request scrolled to one comment thread.
    public func threadURL(_ threadId: Int) -> URL {
        ADOEndpoint.pullRequestPage(
            organization: key.organization, project: projectName, repository: repositoryName, id: key.number, threadId: threadId
        )
    }

    public func reviewer(_ id: String) -> Reviewer? {
        let id = id.lowercased()
        return reviewers.first { $0.person.id == id }
    }

    /// Changes whenever something the list endpoint reports changes, so the details get fetched again.
    public var fingerprint: String {
        let votes = reviewers.map { "\($0.person.id)=\($0.vote.rawValue)\($0.hasDeclined ? "d" : "")" }.sorted()
        return [
            title, status.rawValue, isDraft ? "draft" : "", mergeStatus ?? "", autoComplete ? "auto" : "",
            sourceCommit ?? "", targetCommit ?? "", votes.joined(separator: ","),
        ].joined(separator: "|")
    }
}
