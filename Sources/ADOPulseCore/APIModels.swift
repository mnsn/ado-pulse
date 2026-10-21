import Foundation

// The Azure DevOps REST API (7.1) shapes that ADO Pulse reads. Fields the API may omit are optional.
// A list skips an element it can't decode instead of failing, and the free-form policy settings and
// thread properties treat a value of an unexpected type as missing.

/// JSON decoding for Azure DevOps responses, whose dates are ISO 8601 with varying precision.
public enum ADOJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = Timestamp.parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(string)")
            }
            return date
        }
        return decoder
    }
}

extension KeyedDecodingContainer {
    /// The value, or nil when it's missing, null or of an unexpected type.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// `{"count": n, "value": [...]}`, the envelope of every list.
public struct ADOList<Element: Decodable & Sendable>: Decodable, Sendable {
    public var value: [Element]
    /// Elements that couldn't be decoded and were left out.
    public var skipped = 0

    public init(value: [Element]) {
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case value }

    /// Consumes one element of any shape, to step over one that failed to decode.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var items = try container.nestedUnkeyedContainer(forKey: .value)
        var value: [Element] = []
        while !items.isAtEnd {
            if let element = try? items.decode(Element.self) {
                value.append(element)
            } else {
                _ = try items.decode(Skip.self)
                skipped += 1
            }
        }
        self.value = value
    }
}

public struct ADOConnectionData: Decodable, Sendable {
    public struct User: Decodable, Sendable {
        public var id: String
        public var providerDisplayName: String?
    }

    public var authenticatedUser: User
}

/// `app.vssps.visualstudio.com/_apis/profile/profiles/me`
public struct ADOProfile: Decodable, Sendable {
    public var id: String
    public var publicAlias: String?
}

/// One organization from `app.vssps.visualstudio.com/_apis/accounts`.
public struct ADOAccount: Decodable, Sendable {
    public var accountName: String
}

public struct ADOIdentity: Decodable, Sendable, Equatable {
    public var id: String
    public var displayName: String?
    public var uniqueName: String?
    public var isContainer: Bool?

    public init(id: String, displayName: String? = nil, uniqueName: String? = nil, isContainer: Bool? = nil) {
        self.id = id
        self.displayName = displayName
        self.uniqueName = uniqueName
        self.isContainer = isContainer
    }
}

public struct ADOReviewer: Decodable, Sendable {
    public var id: String
    public var displayName: String?
    public var uniqueName: String?
    public var vote: Int?
    public var isRequired: Bool?
    public var isContainer: Bool?
    public var hasDeclined: Bool?
}

public struct ADOProjectRef: Decodable, Sendable {
    public var id: String
    public var name: String
}

public struct ADORepositoryRef: Decodable, Sendable {
    public var id: String
    public var name: String
    public var project: ADOProjectRef
}

public struct ADOCommitRef: Decodable, Sendable {
    public var commitId: String
}

public struct ADOPullRequest: Decodable, Sendable {
    public var pullRequestId: Int
    public var title: String
    public var status: String
    public var createdBy: ADOIdentity
    public var creationDate: Date
    public var closedDate: Date?
    public var sourceRefName: String?
    public var targetRefName: String?
    /// `succeeded`, `conflicts`, `queued`, `rejectedByPolicy`, `failure` or `notSet`.
    public var mergeStatus: String?
    public var isDraft: Bool?
    public var reviewers: [ADOReviewer]?
    public var repository: ADORepositoryRef
    public var lastMergeSourceCommit: ADOCommitRef?
    public var lastMergeTargetCommit: ADOCommitRef?
    public var autoCompleteSetBy: ADOIdentity?
}

/// The state of one branch policy (a build, a status check, a reviewer rule...) on a pull request.
public struct ADOPolicyEvaluation: Decodable, Sendable {
    /// `queued`, `running`, `approved`, `rejected`, `notApplicable` or `broken`.
    public var status: String?
    public var configuration: Configuration
    public var context: Context?
    public var completedDate: Date?

    public struct Configuration: Decodable, Sendable {
        public var isEnabled: Bool?
        public var isBlocking: Bool?
        public var type: PolicyType
        public var settings: Settings?
    }

    public struct PolicyType: Decodable, Sendable {
        public var displayName: String
    }

    public struct Settings: Decodable, Sendable {
        public var displayName: String?
        public var minimumApproverCount: Int?
        public var statusName: String?
        public var statusGenre: String?
        public var defaultDisplayName: String?

        private enum CodingKeys: String, CodingKey {
            case displayName, minimumApproverCount, statusName, statusGenre, defaultDisplayName
        }

        public init(displayName: String? = nil, minimumApproverCount: Int? = nil, statusName: String? = nil,
                    statusGenre: String? = nil, defaultDisplayName: String? = nil) {
            self.displayName = displayName
            self.minimumApproverCount = minimumApproverCount
            self.statusName = statusName
            self.statusGenre = statusGenre
            self.defaultDisplayName = defaultDisplayName
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            displayName = container.lenient(String.self, forKey: .displayName)
            minimumApproverCount = container.lenient(Int.self, forKey: .minimumApproverCount)
            statusName = container.lenient(String.self, forKey: .statusName)
            statusGenre = container.lenient(String.self, forKey: .statusGenre)
            defaultDisplayName = container.lenient(String.self, forKey: .defaultDisplayName)
        }
    }

    public struct Context: Decodable, Sendable {
        public var buildId: Int?
        public var buildDefinitionName: String?
        public var isExpired: Bool?

        private enum CodingKeys: String, CodingKey { case buildId, buildDefinitionName, isExpired }

        public init(buildId: Int? = nil, buildDefinitionName: String? = nil, isExpired: Bool? = nil) {
            self.buildId = buildId
            self.buildDefinitionName = buildDefinitionName
            self.isExpired = isExpired
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            buildId = container.lenient(Int.self, forKey: .buildId)
            buildDefinitionName = container.lenient(String.self, forKey: .buildDefinitionName)
            isExpired = container.lenient(Bool.self, forKey: .isExpired)
        }
    }

    private enum CodingKeys: String, CodingKey { case status, configuration, context, completedDate }

    public init(status: String?, configuration: Configuration, context: Context? = nil, completedDate: Date? = nil) {
        self.status = status
        self.configuration = configuration
        self.context = context
        self.completedDate = completedDate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.lenient(String.self, forKey: .status)
        configuration = try container.decode(Configuration.self, forKey: .configuration)
        context = container.lenient(Context.self, forKey: .context)
        completedDate = container.lenient(Date.self, forKey: .completedDate)
    }
}

/// A comment thread. Activity (pushes, votes, reviewer changes) is logged as system threads whose
/// `CodeReviewThreadType` property says what happened.
public struct ADOThread: Decodable, Sendable {
    public var id: Int
    public var publishedDate: Date?
    public var lastUpdatedDate: Date?
    /// `active`, `fixed`, `wontFix`, `closed`, `byDesign`, `pending` or `unknown`.
    public var status: String?
    public var isDeleted: Bool?
    public var threadContext: ThreadContext?
    public var comments: [ADOComment]?
    public var properties: [String: ADOProperty]?
    /// Identities that the properties refer to by key, such as who voted.
    public var identities: [String: ADOIdentity]?

    public struct ThreadContext: Decodable, Sendable {
        public var filePath: String?
        public var rightFileStart: Position?
        public var leftFileStart: Position?
    }

    public struct Position: Decodable, Sendable {
        public var line: Int?
    }

    /// The kind of activity a system thread records, e.g. `VoteUpdate` or `RefUpdate`.
    public var activityType: String? {
        properties?["CodeReviewThreadType"]?.value
    }

    public func identity(forProperty name: String) -> ADOIdentity? {
        guard let key = properties?[name]?.value else { return nil }
        return identities?[key]
    }
}

public struct ADOComment: Decodable, Sendable {
    public var id: Int
    public var parentCommentId: Int?
    public var author: ADOIdentity?
    public var content: String?
    public var publishedDate: Date?
    /// `text`, `system` or `codeChange`.
    public var commentType: String?
    public var isDeleted: Bool?
}

/// A thread property: `{"$type": "System.String", "$value": "VoteUpdate"}`. The value is kept as a
/// string whatever its JSON type.
public struct ADOProperty: Decodable, Sendable, Equatable {
    public var value: String?

    public init(_ value: String?) {
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case value = "$value" }

    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            value = nil
            return
        }
        if let string = container.lenient(String.self, forKey: .value) {
            value = string
        } else if let int = container.lenient(Int.self, forKey: .value) {
            value = String(int)
        } else if let double = container.lenient(Double.self, forKey: .value) {
            value = String(double)
        } else if let bool = container.lenient(Bool.self, forKey: .value) {
            value = String(bool)
        } else {
            value = nil
        }
    }
}
