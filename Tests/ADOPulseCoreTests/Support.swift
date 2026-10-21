import Foundation
import Synchronization
import Testing
@testable import ADOPulseCore

/// Fixed reference time for fixtures: 2026-10-18T10:00:00Z.
let referenceDate = Date(timeIntervalSince1970: 1_792_317_600)

/// The reference time plus `seconds`.
func t(_ seconds: TimeInterval) -> Date {
    referenceDate.addingTimeInterval(seconds)
}

let minute: TimeInterval = 60
let hour: TimeInterval = 3_600
let day: TimeInterval = 86_400

func iso(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

struct TestError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

// MARK: - Made-up people and domain values

enum People {
    static let me = Person(id: "11111111-1111-1111-1111-111111111111", name: "Robin Diaz")
    static let sam = Person(id: "22222222-2222-2222-2222-222222222222", name: "Sam Rivera")
    static let priya = Person(id: "33333333-3333-3333-3333-333333333333", name: "Priya Shah")
    static let alex = Person(id: "44444444-4444-4444-4444-444444444444", name: "Alex Kim")
    static let bot = Person(id: "55555555-5555-5555-5555-555555555555", name: "Shop Build Service", isBot: true)
}

func makePR(
    _ number: Int = 7, title: String = "Fix the checkout total", status: PullRequest.Status = .active, author: Person = People.me,
    created: Date = t(-2 * day), closed: Date? = nil, reviewers: [Reviewer] = [], draft: Bool = false,
    merge: String? = "succeeded", autoComplete: Bool = false, organization: String = "contoso"
) -> PullRequest {
    PullRequest(
        key: PRKey(organization, number), title: title, status: status, author: author, createdAt: created, closedAt: closed,
        projectId: "p1", projectName: "Shop", repositoryId: "r1", repositoryName: "shop-web",
        sourceBranch: "fix-total", targetBranch: "main", isDraft: draft, mergeStatus: merge, reviewers: reviewers,
        autoComplete: autoComplete, sourceCommit: "abc", targetCommit: "def"
    )
}

func makeDetails(
    for pr: PullRequest, checks: [Check] = [], checksKnown: Bool = true, threads: [ReviewThread] = [], activity: [Activity] = [],
    lastActivity: Date? = nil
) -> PRDetails {
    let dates = threads.flatMap { $0.comments.map(\.publishedAt) } + activity.map(\.at)
    return PRDetails(
        fetchedAt: t(0), fingerprint: pr.fingerprint, checks: checks, checksKnown: checksKnown, threads: threads, activity: activity,
        lastActivity: lastActivity ?? dates.max()
    )
}

func comment(_ id: Int, _ author: Person, _ text: String = "A comment", at date: Date, mentions: [Person] = []) -> ReviewComment {
    ReviewComment(id: id, author: author, text: text, mentions: mentions.map(\.id), publishedAt: date)
}

// MARK: - Made-up Azure DevOps JSON

enum Fixture {
    static let org = "contoso"
    static let me = People.me.id

    static func identity(_ person: Person, unique: String? = nil) -> [String: Any] {
        ["id": person.id.uppercased(), "displayName": person.name,
         "uniqueName": unique ?? (person.isBot ? "Build\\\(person.id)" : "\(person.firstName.lowercased())@contoso.com")]
    }

    static func reviewer(_ person: Person, vote: Int = 0, required: Bool = false, group: Bool = false) -> [String: Any] {
        var json = identity(person)
        json["vote"] = vote
        json["isRequired"] = required
        if group { json["isContainer"] = true }
        return json
    }

    static func pullRequest(
        _ id: Int, title: String = "Fix the checkout total", author: Person = People.me, reviewers: [[String: Any]] = [],
        created: Date = t(-2 * day), status: String = "active", closed: Date? = nil, merge: String = "succeeded",
        draft: Bool = false, sourceCommit: String = "abc", project: String = "p1", repository: String = "r1"
    ) -> [String: Any] {
        var json: [String: Any] = [
            "pullRequestId": id, "codeReviewId": id, "title": title, "status": status, "createdBy": identity(author),
            "creationDate": iso(created), "sourceRefName": "refs/heads/fix-total", "targetRefName": "refs/heads/main",
            "mergeStatus": merge, "isDraft": draft, "reviewers": reviewers,
            "repository": ["id": repository, "name": "shop-web", "url": "https://example.invalid",
                           "project": ["id": project, "name": "Shop", "state": "wellFormed"]],
            "lastMergeSourceCommit": ["commitId": sourceCommit], "lastMergeTargetCommit": ["commitId": "def"],
            "url": "https://example.invalid", "supportsIterations": true,
        ]
        if let closed { json["closedDate"] = iso(closed) }
        return json
    }

    static func evaluation(
        _ type: String, status: String, blocking: Bool = true, enabled: Bool = true, settings: [String: Any] = [:],
        context: [String: Any]? = nil, completed: Date? = nil
    ) -> [String: Any] {
        var json: [String: Any] = [
            "evaluationId": UUID().uuidString, "status": status,
            "configuration": ["isEnabled": enabled, "isBlocking": blocking, "type": ["id": UUID().uuidString, "displayName": type],
                              "settings": settings],
        ]
        if let context { json["context"] = context }
        if let completed { json["completedDate"] = iso(completed) }
        return json
    }

    static func comment(_ id: Int, _ author: Person, _ content: String, at date: Date, type: String = "text", deleted: Bool = false) -> [String: Any] {
        ["id": id, "parentCommentId": 0, "author": identity(author), "content": content, "publishedDate": iso(date),
         "lastUpdatedDate": iso(date), "commentType": type, "isDeleted": deleted]
    }

    static func thread(
        _ id: Int, comments: [[String: Any]], status: String = "active", published: Date,
        properties: [String: Any]? = nil, identities: [String: Any]? = nil, filePath: String? = nil
    ) -> [String: Any] {
        var json: [String: Any] = [
            "id": id, "publishedDate": iso(published), "lastUpdatedDate": iso(published), "status": status,
            "comments": comments, "isDeleted": false,
        ]
        if let properties { json["properties"] = properties }
        if let identities { json["identities"] = identities }
        if let filePath {
            json["threadContext"] = ["filePath": filePath, "rightFileStart": ["line": 12, "offset": 1], "rightFileEnd": ["line": 12, "offset": 9]]
        }
        return json
    }

    /// A system thread recording activity, such as `VoteUpdate`.
    static func activity(_ id: Int, _ type: String, at date: Date, by person: Person, properties: [String: Any] = [:],
                         identities extra: [String: Any] = [:]) -> [String: Any] {
        var props: [String: Any] = ["CodeReviewThreadType": ["$type": "System.String", "$value": type]]
        for (key, value) in properties { props[key] = ["$type": "System.String", "$value": value] }
        var identities: [String: Any] = ["1": identity(person)]
        for (key, value) in extra { identities[key] = value }
        let byKey = ["VoteUpdate": "CodeReviewVotedByIdentity", "RefUpdate": "CodeReviewRefUpdatedByIdentity",
                     "ReviewersUpdate": "CodeReviewReviewersUpdatedByIdentity"][type]
        if let byKey { props[byKey] = ["$type": "System.String", "$value": "1"] }
        return thread(id, comments: [comment(1, person, "System message", at: date, type: "system")], status: "unknown",
                      published: date, properties: props, identities: identities)
    }

    static func list(_ items: [[String: Any]]) -> [String: Any] {
        ["count": items.count, "value": items]
    }

    static func data(_ object: Any) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try ADOJSON.decoder().decode(type, from: data(object))
    }
}

// MARK: - Tokens and a stub Azure DevOps

actor FakeTokens: AccessTokenProvider {
    private var value: String
    private var error: AuthError?
    private var account: String?
    private(set) var fetches = 0
    private(set) var invalidations = 0

    init(_ value: String, error: AuthError? = nil) {
        self.value = value
        self.error = error
    }

    func token() async throws -> AccessToken {
        fetches += 1
        if let error { throw error }
        return AccessToken(value: value, expiresOn: .distantFuture, account: account)
    }

    func signIn(as account: String?) {
        self.account = account
    }

    func invalidate() {
        invalidations += 1
    }

    func fail(with error: AuthError?) {
        self.error = error
    }
}

/// Answers requests from routes. Each test gets its own server; requests find it through their bearer
/// token, which is the server's ID, so tests can run in parallel.
final class StubServer: Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"]
        var body = Data()
        var error: URLError?

        static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            var reply = Reply(status: status, body: Fixture.data(object))
            reply.headers.merge(headers) { $1 }
            return reply
        }

        static func status(_ status: Int, headers: [String: String] = [:]) -> Reply {
            var reply = Reply(status: status, body: Data("{}".utf8))
            reply.headers.merge(headers) { $1 }
            return reply
        }

        static func failure(_ code: URLError.Code) -> Reply {
            Reply(error: URLError(code))
        }
    }

    typealias Handler = @Sendable (URLRequest) -> Reply?

    let id = UUID().uuidString
    private let routes = Mutex<[Handler]>([])
    private let log = Mutex<[URLRequest]>([])

    init() {
        StubRegistry.servers.withLock { $0[id] = self }
    }

    var tokens: FakeTokens { FakeTokens(id) }

    func client(tokens: (any AccessTokenProvider)? = nil) -> ADOClient {
        ADOClient(tokens: tokens ?? FakeTokens(id), session: ADOClient.makeSession(protocolClasses: [StubURLProtocol.self]))
    }

    /// Answers requests whose path contains `path` (and whose query has every given item).
    func on(_ path: String, query: [String: String] = [:], reply: @escaping @Sendable (URLRequest) -> Reply) {
        routes.withLock {
            $0.insert({ request in
                guard let url = request.url, url.path.contains(path) else { return nil }
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                for (name, value) in query where !items.contains(where: { $0.name == name && $0.value?.lowercased() == value.lowercased() }) {
                    return nil
                }
                return reply(request)
            }, at: 0)
        }
    }

    func on(_ path: String, query: [String: String] = [:], json object: Any) {
        let reply = Reply.json(object)
        on(path, query: query) { _ in reply }
    }

    var requests: [URLRequest] { log.withLock { $0 } }

    func handle(_ request: URLRequest) -> Reply {
        log.withLock { $0.append(request) }
        let handlers = routes.withLock { $0 }
        for handler in handlers {
            if let reply = handler(request) { return reply }
        }
        return .status(404)
    }

    /// Serves an organization: who you are, your pull request lists, and each pull request's details.
    func serveOrganization(
        _ organization: String = Fixture.org, me: String = Fixture.me, mine: [[String: Any]] = [], reviewing: [[String: Any]] = [],
        completed: [[String: Any]] = []
    ) {
        on("/\(organization)/_apis/connectionData", json: ["authenticatedUser": ["id": me.uppercased()]])
        on("/\(organization)/_apis/git/pullrequests", query: ["searchCriteria.creatorId": me, "searchCriteria.status": "active"],
           json: Fixture.list(mine))
        on("/\(organization)/_apis/git/pullrequests", query: ["searchCriteria.reviewerId": me, "searchCriteria.status": "active"],
           json: Fixture.list(reviewing))
        on("/\(organization)/_apis/git/pullrequests", query: ["searchCriteria.creatorId": me, "searchCriteria.status": "completed"],
           json: Fixture.list(completed))
        on("/_apis/policy/evaluations", json: Fixture.list([]))
        on("/threads", json: Fixture.list([]))
    }
}

enum StubRegistry {
    static let servers = Mutex<[String: StubServer]>([:])
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        guard let server = StubRegistry.servers.withLock({ $0[token] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let reply = server.handle(request)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Collects what a running engine publishes.
final class SnapshotCollector: Sendable {
    private let snapshots = Mutex<[PulseSnapshot]>([])

    func add(_ snapshot: PulseSnapshot) {
        snapshots.withLock { $0.append(snapshot) }
    }

    var count: Int { snapshots.withLock { $0.count } }

    var last: PulseSnapshot? { snapshots.withLock { $0.last } }

    @discardableResult
    func wait(_ what: String, timeout: Duration = .seconds(10), until predicate: (PulseSnapshot) -> Bool) async throws -> PulseSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let latest = snapshots.withLock({ $0.last }), predicate(latest) { return latest }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestError("Timed out waiting for \(what) after \(count) snapshot(s)")
    }
}
