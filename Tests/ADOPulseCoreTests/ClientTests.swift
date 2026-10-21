import Foundation
import Testing
@testable import ADOPulseCore

@Suite struct DecodingTests {
    @Test func decodesAPullRequestList() throws {
        let json = Fixture.list([
            Fixture.pullRequest(7, reviewers: [Fixture.reviewer(People.sam, vote: 10, required: true),
                                               Fixture.reviewer(People.priya, vote: -5)], draft: true),
        ])
        let list = try Fixture.decode(ADOList<ADOPullRequest>.self, json)
        let pr = PullRequest(organization: "contoso", try #require(list.value.first))
        #expect(pr.key == PRKey("contoso", 7))
        #expect(pr.title == "Fix the checkout total")
        #expect(pr.status == .active)
        #expect(pr.isDraft)
        #expect(pr.sourceBranch == "fix-total")
        #expect(pr.targetBranch == "main")
        #expect(pr.author == People.me)
        #expect(pr.createdAt == t(-2 * day))
        #expect(pr.reviewers.map(\.vote) == [.approved, .waitingForAuthor])
        #expect(pr.reviewers.first?.isRequired == true)
        #expect(pr.reviewer(People.priya.id.uppercased())?.person.name == "Priya Shah")
        #expect(pr.webURL.absoluteString == "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/7")
        #expect(pr.threadURL(42).absoluteString == "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/7?discussionId=42")
    }

    @Test func skipsAnElementItCannotDecode() throws {
        var broken = Fixture.pullRequest(8)
        broken["creationDate"] = "yesterday"
        let list = try Fixture.decode(ADOList<ADOPullRequest>.self, Fixture.list([Fixture.pullRequest(7), broken, Fixture.pullRequest(9)]))
        #expect(list.value.map(\.pullRequestId) == [7, 9])
        #expect(list.skipped == 1)
    }

    @Test func toleratesMissingOptionalFields() throws {
        let minimal: [String: Any] = [
            "pullRequestId": 3, "title": "Minimal", "status": "completed",
            "createdBy": ["id": "ABC"], "creationDate": "2026-10-18T10:00:00Z",
            "repository": ["id": "r", "name": "repo", "project": ["id": "p", "name": "Project"]],
        ]
        let pr = PullRequest(organization: "contoso", try Fixture.decode(ADOPullRequest.self, minimal))
        #expect(pr.status == .completed)
        #expect(pr.reviewers.isEmpty)
        #expect(!pr.isDraft)
        #expect(pr.author.name == "Someone")
        #expect(pr.author.id == "abc")
    }

    @Test func readsThreadPropertiesOfAnyType() throws {
        let json: [String: Any] = [
            "id": 1, "comments": [],
            "properties": [
                "CodeReviewThreadType": ["$type": "System.String", "$value": "RefUpdate"],
                "CodeReviewRefNewCommitsCount": ["$type": "System.Int32", "$value": 3],
                "SupportsMarkdown": ["$type": "System.Boolean", "$value": true],
                "Odd": "not an object",
            ],
        ]
        let thread = try Fixture.decode(ADOThread.self, json)
        #expect(thread.activityType == "RefUpdate")
        #expect(thread.properties?["CodeReviewRefNewCommitsCount"]?.value == "3")
        #expect(thread.properties?["SupportsMarkdown"]?.value == "true")
        #expect(thread.properties?["Odd"]?.value == nil)
    }

    @Test func policySettingsOfAnUnexpectedTypeAreIgnored() throws {
        let json = Fixture.evaluation("Minimum number of reviewers", status: "queued",
                                      settings: ["minimumApproverCount": "two", "creatorVoteCounts": false])
        let evaluation = try Fixture.decode(ADOPolicyEvaluation.self, json)
        #expect(evaluation.configuration.settings?.minimumApproverCount == nil)
        #expect(evaluation.status == "queued")
    }
}

@Suite struct AuthTests {
    @Test func parsesTheCLIToken() throws {
        let json = #"{"accessToken": "abc", "expiresOn": "2026-10-21 10:31:46.000000", "expires_on": 1792564306, "tenant": "t", "tokenType": "Bearer"}"#
        let token = try AzureCLITokenProvider.parseToken(Data(json.utf8), now: t(0))
        #expect(token.value == "abc")
        #expect(token.expiresOn == Date(timeIntervalSince1970: 1_792_564_306))
    }

    @Test func fallsBackToTheLocalExpiryTime() throws {
        let json = #"{"accessToken": "abc", "expiresOn": "2026-10-21 10:31:46.000000"}"#
        let token = try AzureCLITokenProvider.parseToken(Data(json.utf8), now: t(0))
        var components = DateComponents(year: 2026, month: 10, day: 21, hour: 10, minute: 31, second: 46)
        components.timeZone = .current
        #expect(token.expiresOn == Calendar(identifier: .gregorian).date(from: components))

        let undated = try AzureCLITokenProvider.parseToken(Data(#"{"accessToken": "abc"}"#.utf8), now: t(0))
        #expect(undated.expiresOn == t(30 * minute))
    }

    @Test func readsWhoATokenIsFor() throws {
        func jwt(_ claims: String) -> String {
            let payload = Data(claims.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJub25lIn0.\(payload).c2ln"
        }
        let token = jwt(#"{"tid":"T1","oid":"O-1","upn":"robin@contoso.com"}"#)
        #expect(AccessToken.account(inJWT: token) == "t1/o-1")
        let parsed = try AzureCLITokenProvider.parseToken(Data(#"{"accessToken": "\#(token)", "expires_on": 1792564306}"#.utf8), now: t(0))
        #expect(parsed.account == "t1/o-1")
        #expect(AccessToken.account(inJWT: jwt(#"{"sub":"S"}"#)) == "/s")
        #expect(AccessToken.account(inJWT: "opaque") == nil)
        #expect(AccessToken.account(inJWT: "a.b.c") == nil)
    }

    @Test func rejectsOutputWithoutAToken() {
        #expect(throws: AuthError.failed("The Azure CLI returned no token.")) {
            try AzureCLITokenProvider.parseToken(Data("{}".utf8), now: t(0))
        }
    }

    @Test(arguments: [
        ("ERROR: Please run 'az login' to setup account.", true),
        ("ERROR: AADSTS700082: The refresh token has expired due to inactivity.", true),
        ("ERROR: User 'x' does not exist in MSAL token cache. Run `az login`.", true),
        ("WARNING: something\nERROR: Connection reset by peer", false),
    ])
    func tellsASignedOutCLIFromOtherFailures(_ output: String, _ signedOut: Bool) {
        let error = AzureCLITokenProvider.error(fromOutput: output)
        if signedOut {
            guard case .signedOut(let message) = error else { Issue.record("Expected signedOut, got \(error)"); return }
            #expect(!message.hasPrefix("ERROR:"))
        } else {
            #expect(error == .failed("Connection reset by peer"))
        }
    }

    @Test func addsTheUsualPlacesToPath() {
        let environment = AzureCLITokenProvider.environment(base: ["PATH": "/usr/bin:/custom/bin", "HOME": "/Users/x"])
        #expect(environment["PATH"] == "/usr/bin:/custom/bin:/opt/homebrew/bin:/usr/local/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["HOME"] == "/Users/x")
        #expect(environment["AZURE_CORE_COLLECT_TELEMETRY"] == "false")
    }

    @Test func locatesTheCLI() async {
        let present: Set<String> = ["/usr/local/bin/az", "/custom/az"]
        let check: @Sendable (String) -> Bool = { present.contains($0) }
        let usual = AzureCLILocator(environment: [:], useLoginShell: false, isExecutable: check)
        #expect(await usual.locate()?.path == "/usr/local/bin/az")
        let overridden = AzureCLILocator(environment: ["ADO_PULSE_AZ": "/custom/az"], useLoginShell: false, isExecutable: check)
        #expect(await overridden.locate()?.path == "/custom/az")
        let missing = AzureCLILocator(environment: [:], useLoginShell: false, isExecutable: { _ in false })
        #expect(await missing.locate() == nil)
    }

    @Test func asksALoginShellAsALastResort() async {
        struct Shell: ProcessRunning {
            func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
                ProcessResult(status: 0, stdout: Data("Welcome!\n/somewhere/bin/az\n".utf8))
            }
        }
        let locator = AzureCLILocator(environment: [:], candidates: [], runner: Shell(), isExecutable: { $0 == "/somewhere/bin/az" })
        #expect(await locator.locate()?.path == "/somewhere/bin/az")
    }

    @Test func cachesTokensUntilTheyNearExpiry() async throws {
        final class Runs: Sendable {
            let count = Locked(0)
        }
        struct CLI: ProcessRunning {
            let runs: Runs
            func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
                let run = runs.count.increment()
                #expect(arguments.starts(with: ["account", "get-access-token", "--resource", AzureCLITokenProvider.azureDevOpsResource]))
                #expect(environment?["AZURE_CORE_ONLY_SHOW_ERRORS"] == "true")
                let expiry = Int(t(Double(run) * 600).timeIntervalSince1970)
                return ProcessResult(status: 0, stdout: Data(#"{"accessToken": "token\#(run)", "expires_on": \#(expiry)}"#.utf8))
            }
        }
        let runs = Runs()
        let clock = Locked(t(0))
        let provider = AzureCLITokenProvider(
            locator: AzureCLILocator(environment: [:], candidates: ["/bin/az"], useLoginShell: false, isExecutable: { _ in true }),
            runner: CLI(runs: runs), now: { clock.value }
        )
        #expect(try await provider.token().value == "token1")
        #expect(try await provider.token().value == "token1")
        // Within five minutes of expiring, it asks again.
        clock.set(t(301))
        #expect(try await provider.token().value == "token2")
        await provider.invalidate()
        #expect(try await provider.token().value == "token3")
        #expect(runs.count.value == 3)
    }

    @Test func reportsAMissingCLI() async {
        let provider = AzureCLITokenProvider(locator: AzureCLILocator(environment: [:], candidates: [], useLoginShell: false))
        await #expect(throws: AuthError.cliNotFound) { try await provider.token() }
    }

    @Test func runsAProgramAndCollectsItsOutput() async throws {
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"], environment: nil, timeout: 10
        )
        #expect(result.status == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
    }

    @Test(.timeLimit(.minutes(1)))
    func endsAProgramThatRunsTooLong() async throws {
        let start = Date()
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: nil, timeout: 0.5)
        #expect(result.status != 0)
        #expect(Date().timeIntervalSince(start) < 10)
    }
}

/// A tiny lock-protected value for test bookkeeping.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value { lock.withLock { stored } }

    func set(_ value: Value) {
        lock.withLock { stored = value }
    }
}

extension Locked where Value == Int {
    @discardableResult
    func increment() -> Int {
        lock.withLock {
            stored += 1
            return stored
        }
    }
}

@Suite struct ClientTests {
    @Test func buildsEndpointURLs() {
        #expect(ADOEndpoint.connectionData(organization: "contoso").absoluteString == "https://dev.azure.com/contoso/_apis/connectionData")
        #expect(ADOEndpoint.pullRequests(organization: "contoso", creatorId: "me", status: "active").absoluteString
            == "https://dev.azure.com/contoso/_apis/git/pullrequests?searchCriteria.creatorId=me&searchCriteria.status=active&$top=200&api-version=7.1")
        #expect(ADOEndpoint.pullRequests(organization: "contoso", creatorId: "me", status: "completed", closedSince: t(0), top: 50).absoluteString
            == "https://dev.azure.com/contoso/_apis/git/pullrequests?searchCriteria.creatorId=me&searchCriteria.status=completed"
            + "&searchCriteria.minTime=2026-10-18T10%3A00%3A00Z&searchCriteria.queryTimeRangeType=closed&$top=50&api-version=7.1")
        // The artifact ID is encoded completely, slashes and colons included.
        #expect(ADOEndpoint.policyEvaluations(organization: "contoso", projectId: "p1", pullRequestId: 7).absoluteString
            == "https://dev.azure.com/contoso/p1/_apis/policy/evaluations?artifactId=vstfs%3A%2F%2F%2FCodeReview%2FCodeReviewId%2Fp1%2F7&api-version=7.1-preview.1")
        #expect(ADOEndpoint.threads(organization: "contoso", projectId: "p1", repositoryId: "r1", pullRequestId: 7).absoluteString
            == "https://dev.azure.com/contoso/p1/_apis/git/repositories/r1/pullRequests/7/threads?api-version=7.1")
        #expect(ADOEndpoint.pullRequestPage(organization: "contoso", project: "My Project", repository: "web app", id: 7).absoluteString
            == "https://dev.azure.com/contoso/My%20Project/_git/web%20app/pullrequest/7")
        #expect(ADOEndpoint.myPullRequestsPage(organization: "contoso").absoluteString == "https://dev.azure.com/contoso/_pulls")
    }

    @Test func sendsOnlyGETRequestsWithABearerToken() async throws {
        let server = StubServer()
        server.on("/_apis/connectionData", json: ["authenticatedUser": ["id": "ME"]])
        let me = try await server.client().get(ADOEndpoint.connectionData(organization: "contoso"), as: ADOConnectionData.self)
        #expect(me.authenticatedUser.id == "ME")
        let request = try #require(server.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(server.id)")
        #expect(request.value(forHTTPHeaderField: "X-TFS-FedAuthRedirect") == "Suppress")
        #expect(request.httpBody == nil)
    }

    @Test func retriesOnceWithAFreshTokenWhenTheTokenIsRejected() async throws {
        let server = StubServer()
        let attempts = Locked(0)
        server.on("/_apis/connectionData") { _ in
            attempts.increment() == 1 ? .status(401) : .json(["authenticatedUser": ["id": "ME"]])
        }
        let tokens = server.tokens
        _ = try await server.client(tokens: tokens).get(ADOEndpoint.connectionData(organization: "contoso"), as: ADOConnectionData.self)
        #expect(await tokens.invalidations == 1)
        #expect(await tokens.fetches == 2)

        // A sign-in page instead of JSON means the same; twice in a row is an error.
        server.on("/_apis/connectionData") { _ in
            StubServer.Reply(status: 203, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8))
        }
        await #expect(throws: ADOError.unauthorized) {
            try await server.client().get(ADOEndpoint.connectionData(organization: "contoso"), as: ADOConnectionData.self)
        }
    }

    @Test func mapsFailures() async {
        let server = StubServer()
        let client = server.client()
        let url = ADOEndpoint.connectionData(organization: "contoso")
        let cases: [(StubServer.Reply, ADOError)] = [
            (.status(403), .forbidden),
            (.status(404), .notFound),
            (.status(500), .http(500)),
            (.failure(.notConnectedToInternet), .offline),
            (.failure(.timedOut), .network("Azure DevOps didn't answer in time.")),
        ]
        for (reply, expected) in cases {
            server.on("/_apis/connectionData") { _ in reply }
            await #expect(throws: expected) { try await client.get(url, as: ADOConnectionData.self) }
        }
    }

    @Test func honorsRetryAfter() async throws {
        let server = StubServer()
        server.on("/_apis/connectionData") { _ in .status(429, headers: ["Retry-After": "30"]) }
        let client = server.client()
        let url = ADOEndpoint.connectionData(organization: "contoso")
        await #expect(throws: ADOError.throttled(retryAfter: 30)) { try await client.get(url, as: ADOConnectionData.self) }

        // Until then, nothing is sent.
        server.on("/_apis/connectionData", json: ["authenticatedUser": ["id": "ME"]])
        let sent = server.requests.count
        do {
            _ = try await client.get(url, as: ADOConnectionData.self)
            Issue.record("Expected to be throttled")
        } catch ADOError.throttled(let wait) {
            #expect(wait > 25 && wait <= 30)
        }
        #expect(server.requests.count == sent)
    }

    @Test func reportsAuthFailures() async {
        let server = StubServer()
        let client = server.client(tokens: FakeTokens(server.id, error: .signedOut("Run az login")))
        await #expect(throws: ADOError.auth(.signedOut("Run az login"))) {
            try await client.get(ADOEndpoint.connectionData(organization: "contoso"), as: ADOConnectionData.self)
        }
    }

    @Test func validatesOrganizationNames() {
        #expect(OrganizationDiscovery.isValidName("contoso"))
        #expect(OrganizationDiscovery.isValidName("contoso-2"))
        #expect(!OrganizationDiscovery.isValidName(""))
        #expect(!OrganizationDiscovery.isValidName("-contoso"))
        #expect(!OrganizationDiscovery.isValidName("con toso"))
        #expect(!OrganizationDiscovery.isValidName("contoso/web"))
    }

    @Test func mergesOrganizationNamesIgnoringCase() {
        #expect(OrganizationDiscovery.merged(["contoso", "zeta"], preferring: ["Contoso", "Fabrikam"]) == ["Contoso", "Fabrikam", "zeta"])
        #expect(OrganizationDiscovery.merged(["b", "A", "a"], preferring: []) == ["b", "A"].sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test(arguments: [
        ("contoso", "contoso"), ("  contoso \n", "contoso"), ("https://dev.azure.com/contoso", "contoso"),
        ("dev.azure.com/contoso/Shop/_git/web/pullrequest/7", "contoso"), ("https://contoso.visualstudio.com/Shop/_git/web", "contoso"),
        ("contoso.visualstudio.com", "contoso"), ("https://dev.azure.com", nil), ("", nil), ("not an org", nil),
        ("https://github.com/contoso/web", nil),
    ] as [(String, String?)])
    func readsOrganizationNamesFromLinks(_ input: String, _ expected: String?) {
        #expect(OrganizationDiscovery.name(from: input) == expected)
    }

    @Test func discoversOrganizationsWithPullRequests() async throws {
        let server = StubServer()
        server.on("/_apis/profile/profiles/me", json: ["id": "profile-id", "publicAlias": "alias"])
        server.on("/_apis/accounts", query: ["memberId": "alias"], json: Fixture.list([
            ["accountName": "fabrikam"], ["accountName": "Contoso"], ["accountName": "northwind"], ["accountName": "locked"],
        ]))
        for organization in ["fabrikam", "Contoso", "northwind"] {
            server.on("/\(organization)/_apis/connectionData", json: ["authenticatedUser": ["id": "ME"]])
        }
        server.on("/locked/_apis/connectionData") { _ in .status(401) }
        server.on("/fabrikam/_apis/git/pullrequests", json: Fixture.list([]))
        server.on("/northwind/_apis/git/pullrequests", query: ["searchCriteria.reviewerId": "ME"], json: Fixture.list([Fixture.pullRequest(3)]))
        server.on("/northwind/_apis/git/pullrequests", query: ["searchCriteria.creatorId": "ME"], json: Fixture.list([]))
        server.on("/Contoso/_apis/git/pullrequests", json: Fixture.list([Fixture.pullRequest(1)]))

        let client = server.client()
        let all = try await OrganizationDiscovery.memberships(client: client)
        #expect(all == ["Contoso", "fabrikam", "locked", "northwind"])
        #expect(await OrganizationDiscovery.withPullRequests(all, client: client) == ["Contoso", "northwind"])
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}
