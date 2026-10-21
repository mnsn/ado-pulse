import Foundation

public enum ADOError: Error, Sendable, Equatable, CustomStringConvertible {
    case auth(AuthError)
    /// Azure DevOps rejected the token, even a fresh one.
    case unauthorized
    /// Signed in, but without access to this organization or project.
    case forbidden
    case notFound
    /// Azure DevOps asked us to slow down.
    case throttled(retryAfter: TimeInterval)
    case offline
    case http(Int)
    case network(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .auth(let error): return error.description
        case .unauthorized: return "Azure DevOps didn't accept the sign-in."
        case .forbidden: return "No access to this organization."
        case .notFound: return "Not found."
        case .throttled: return "Azure DevOps asked ADO Pulse to slow down."
        case .offline: return "You're offline."
        case .http(let status): return "Azure DevOps answered with HTTP \(status)."
        case .network(let message): return message
        case .decoding(let message): return "Unexpected response from Azure DevOps (\(message))."
        }
    }
}

/// Reads from Azure DevOps. It only ever sends GET requests: ADO Pulse never changes anything there.
public struct ADOClient: Sendable {
    public let tokens: any AccessTokenProvider
    let session: URLSession
    let gate: RateLimitGate

    public init(tokens: any AccessTokenProvider, session: URLSession = ADOClient.makeSession()) {
        self.tokens = tokens
        self.session = session
        gate = RateLimitGate()
    }

    /// No cookies, no cache and no credentials kept: every request carries its own bearer token.
    public static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "ADOPulse"]
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration)
    }

    public func get<T: Decodable>(_ url: URL, as type: T.Type = T.self) async throws -> T {
        let data = try await data(url)
        do {
            return try ADOJSON.decoder().decode(T.self, from: data)
        } catch {
            throw ADOError.decoding(Self.describe(error))
        }
    }

    /// The only way requests are made: GET, with a bearer token, retried once with a fresh token if it's rejected.
    func data(_ url: URL) async throws -> Data {
        if let wait = await gate.remainingWait(), wait > 0 {
            throw ADOError.throttled(retryAfter: wait)
        }
        var token = try await accessToken()
        for attempt in 0..<2 {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: Self.request(url, token: token.value))
            } catch let error as URLError {
                throw Self.map(error)
            } catch {
                throw ADOError.network(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                throw ADOError.network("No response from Azure DevOps.")
            }
            if let retryAfter = Self.retryAfter(http) {
                await gate.hold(for: retryAfter)
            }
            switch http.statusCode {
            case 200..<300 where http.statusCode != 203 && Self.isJSON(http):
                return data
            case 200..<300, 401:
                // 203 with a sign-in page is how Azure DevOps answers a request it didn't authenticate.
                if attempt == 0 {
                    await tokens.invalidate()
                    token = try await accessToken()
                    continue
                }
                throw ADOError.unauthorized
            case 403: throw ADOError.forbidden
            case 404: throw ADOError.notFound
            case 429, 503: throw ADOError.throttled(retryAfter: Self.retryAfter(http) ?? 60)
            default: throw ADOError.http(http.statusCode)
            }
        }
        throw ADOError.unauthorized
    }

    private func accessToken() async throws -> AccessToken {
        do {
            return try await tokens.token()
        } catch let error as AuthError {
            throw ADOError.auth(error)
        }
    }

    static func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Answer an unauthenticated request with 401 instead of a redirect to the sign-in page.
        request.setValue("Suppress", forHTTPHeaderField: "X-TFS-FedAuthRedirect")
        return request
    }

    static func isJSON(_ response: HTTPURLResponse) -> Bool {
        (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("json")
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              let seconds = TimeInterval(value), seconds > 0
        else { return nil }
        return min(seconds, 3_600)
    }

    static func map(_ error: URLError) -> ADOError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut: return .network("Azure DevOps didn't answer in time.")
        case .cannotFindHost, .dnsLookupFailed: return .network("Can't reach Azure DevOps.")
        default: return .network(error.localizedDescription)
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: error) }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \(([key] + context.codingPath.reversed()).map(\.stringValue).reversed().joined(separator: "."))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return context.codingPath.map(\.stringValue).joined(separator: ".") + ": " + context.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }
}

/// Remembers how long Azure DevOps asked us to wait (`Retry-After`), so no request goes out before then.
actor RateLimitGate {
    private var notBefore = Date.distantPast

    func hold(for seconds: TimeInterval) {
        notBefore = max(notBefore, Date().addingTimeInterval(seconds))
    }

    func remainingWait() -> TimeInterval? {
        let wait = notBefore.timeIntervalSinceNow
        return wait > 0 ? wait : nil
    }
}

/// The REST endpoints ADO Pulse reads, and the web pages it opens.
public enum ADOEndpoint {
    static let apiVersion = "7.1"

    public static func connectionData(organization: String) -> URL {
        url("https://dev.azure.com", [organization, "_apis", "connectionData"], [])
    }

    /// Pull requests across every project in the organization.
    public static func pullRequests(
        organization: String, creatorId: String? = nil, reviewerId: String? = nil, status: String,
        closedSince: Date? = nil, top: Int = 200
    ) -> URL {
        var query: [(String, String)] = []
        if let creatorId { query.append(("searchCriteria.creatorId", creatorId)) }
        if let reviewerId { query.append(("searchCriteria.reviewerId", reviewerId)) }
        query.append(("searchCriteria.status", status))
        if let closedSince {
            query.append(("searchCriteria.minTime", closedSince.formatted(.iso8601)))
            query.append(("searchCriteria.queryTimeRangeType", "closed"))
        }
        query.append(("$top", String(top)))
        query.append(("api-version", apiVersion))
        return url("https://dev.azure.com", [organization, "_apis", "git", "pullrequests"], query)
    }

    public static func pullRequest(organization: String, id: Int) -> URL {
        url("https://dev.azure.com", [organization, "_apis", "git", "pullrequests", String(id)], [("api-version", apiVersion)])
    }

    /// Branch policies (builds, status checks, reviewer rules...) and how each one stands.
    public static func policyEvaluations(organization: String, projectId: String, pullRequestId: Int) -> URL {
        let artifact = "vstfs:///CodeReview/CodeReviewId/\(projectId)/\(pullRequestId)"
        return url("https://dev.azure.com", [organization, projectId, "_apis", "policy", "evaluations"],
                   [("artifactId", artifact), ("api-version", "7.1-preview.1")])
    }

    public static func threads(organization: String, projectId: String, repositoryId: String, pullRequestId: Int) -> URL {
        url("https://dev.azure.com",
            [organization, projectId, "_apis", "git", "repositories", repositoryId, "pullRequests", String(pullRequestId), "threads"],
            [("api-version", apiVersion)])
    }

    public static let profile = url("https://app.vssps.visualstudio.com", ["_apis", "profile", "profiles", "me"],
                                    [("api-version", apiVersion)])

    public static func accounts(memberId: String) -> URL {
        url("https://app.vssps.visualstudio.com", ["_apis", "accounts"], [("memberId", memberId), ("api-version", apiVersion)])
    }

    // MARK: Web pages

    public static func pullRequestPage(organization: String, project: String, repository: String, id: Int, threadId: Int? = nil) -> URL {
        url("https://dev.azure.com", [organization, project, "_git", repository, "pullrequest", String(id)],
            threadId.map { [("discussionId", String($0))] } ?? [])
    }

    /// The organization's "My pull requests" page.
    public static func myPullRequestsPage(organization: String) -> URL {
        url("https://dev.azure.com", [organization, "_pulls"], [])
    }

    /// Builds a URL from unencoded path segments and query items, percent-encoding everything that
    /// isn't unreserved, so names with spaces and IDs like `vstfs:///...` travel intact.
    static func url(_ base: String, _ segments: [String], _ query: [(String, String)]) -> URL {
        var string = base
        for segment in segments {
            string += "/" + encode(segment)
        }
        if !query.isEmpty {
            string += "?" + query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        }
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid URL: \(string)")
        }
        return url
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~$")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }
}
