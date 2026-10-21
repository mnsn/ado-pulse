import Foundation

/// A bearer token for Azure DevOps.
public struct AccessToken: Sendable, Equatable {
    public var value: String
    public var expiresOn: Date
    /// Who it's for, when the token says: a different one means someone else signed in.
    public var account: String?

    public init(value: String, expiresOn: Date, account: String? = nil) {
        self.value = value
        self.expiresOn = expiresOn
        self.account = account
    }

    /// The tenant and object ID in a Microsoft Entra token (a JWT), read without checking its signature: it
    /// only tells one sign-in from another. Nil for a token that isn't a JWT.
    public static func account(inJWT token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let subject = (claims["oid"] as? String) ?? (claims["sub"] as? String)
        return subject.map { "\(claims["tid"] as? String ?? "")/\($0)".lowercased() }
    }

    /// Valid for at least `margin` more seconds.
    public func isValid(at date: Date, margin: TimeInterval = 300) -> Bool {
        expiresOn.timeIntervalSince(date) > margin
    }
}

public enum AuthError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The Azure CLI isn't installed, or isn't where we look.
    case cliNotFound
    /// The sign-in is missing or has expired: `az login` fixes it.
    case signedOut(String)
    case failed(String)

    public var description: String {
        switch self {
        case .cliNotFound: return "The Azure CLI (az) isn't installed."
        case .signedOut(let message): return message.isEmpty ? "Not signed in to the Azure CLI." : message
        case .failed(let message): return message
        }
    }
}

/// Where tokens come from. ADO Pulse ships the Azure CLI provider; an MSAL provider can implement
/// this too once there's an app registration (a client ID) to sign in with.
public protocol AccessTokenProvider: Sendable {
    func token() async throws -> AccessToken
    /// Forgets a token the server rejected, so the next call gets a fresh one.
    func invalidate() async
}

/// Gets tokens from the Azure CLI's sign-in (`az login`), silently, the way `az` itself does.
public actor AzureCLITokenProvider: AccessTokenProvider {
    /// The application ID of Azure DevOps, the resource tokens are requested for.
    public static let azureDevOpsResource = "499b84ac-1321-427f-aa17-267ca6975798"

    private let locator: AzureCLILocator
    private let runner: any ProcessRunning
    private let tenant: String?
    private let now: @Sendable () -> Date
    private var executable: URL?
    private var cached: AccessToken?
    private var pending: Task<AccessToken, Error>?

    public init(
        tenant: String? = nil, locator: AzureCLILocator = AzureCLILocator(), runner: any ProcessRunning = ProcessRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tenant = tenant
        self.locator = locator
        self.runner = runner
        self.now = now
    }

    public func token() async throws -> AccessToken {
        if let cached, cached.isValid(at: now()) { return cached }
        // Callers asking at the same time share one `az` run.
        if let pending { return try await pending.value }
        let task = Task { try await self.fetch() }
        pending = task
        defer { pending = nil }
        let token = try await task.value
        cached = token
        return token
    }

    public func invalidate() {
        cached = nil
    }

    /// The `az` executable this provider runs, once it has looked for it.
    public var executablePath: String? { executable?.path }

    private func fetch() async throws -> AccessToken {
        if executable == nil {
            executable = await locator.locate()
        }
        guard let executable else { throw AuthError.cliNotFound }
        var arguments = ["account", "get-access-token", "--resource", Self.azureDevOpsResource, "--output", "json"]
        if let tenant, !tenant.isEmpty {
            arguments += ["--tenant", tenant]
        }
        let result: ProcessResult
        do {
            result = try await runner.run(executable, arguments: arguments, environment: Self.environment(), timeout: 60)
        } catch {
            // It may have been uninstalled or moved: look again next time.
            self.executable = nil
            throw AuthError.failed("Couldn't run the Azure CLI: \(error.localizedDescription)")
        }
        guard result.status == 0 else {
            throw Self.error(fromOutput: String(decoding: result.stderr, as: UTF8.self))
        }
        return try Self.parseToken(result.stdout, now: now())
    }

    /// `az` is a Python program; a Mac app doesn't get the shell's PATH, so add the usual places, and keep
    /// these runs quiet and out of the CLI's telemetry.
    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let usual = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (path + usual.filter { !path.contains($0) }).joined(separator: ":")
        environment["AZURE_CORE_COLLECT_TELEMETRY"] = "false"
        environment["AZURE_CORE_ONLY_SHOW_ERRORS"] = "true"
        environment["AZURE_CORE_NO_COLOR"] = "true"
        return environment
    }

    /// Parses `az account get-access-token --output json`.
    static func parseToken(_ data: Data, now: Date) throws -> AccessToken {
        struct Output: Decodable {
            var accessToken: String
            /// Seconds since 1970, in newer versions of the CLI.
            var expires_on: Double?
            /// Local time, such as `2026-10-21 10:31:46.000000`.
            var expiresOn: String?
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: data), !output.accessToken.isEmpty else {
            throw AuthError.failed("The Azure CLI returned no token.")
        }
        let expiry = output.expires_on.map { Date(timeIntervalSince1970: $0) }
            ?? output.expiresOn.flatMap(parseLocalTime)
            ?? now.addingTimeInterval(30 * 60)
        return AccessToken(value: output.accessToken, expiresOn: expiry, account: AccessToken.account(inJWT: output.accessToken))
    }

    static func parseLocalTime(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    /// Tells a missing or expired sign-in, which `az login` fixes, from other failures.
    static func error(fromOutput output: String) -> AuthError {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let message = (lines.first { $0.hasPrefix("ERROR:") } ?? lines.first ?? "The Azure CLI failed.")
            .replacingOccurrences(of: "ERROR: ", with: "")
        let lower = output.lowercased()
        let signedOutHints = [
            "az login", "please run", "aadsts", "interaction_required", "invalid_grant",
            "refresh token", "no subscription", "not logged in", "does not exist in msal token cache",
        ]
        if signedOutHints.contains(where: lower.contains) {
            return .signedOut(String(message.prefix(300)))
        }
        return .failed(String(message.prefix(300)))
    }
}

/// Finds `az` without relying on PATH: apps opened from Finder or as login items get only the system's.
public struct AzureCLILocator: Sendable {
    public var override: String?
    public var candidates: [String]
    /// Ask a login shell (`command -v az`) when it isn't in a usual place.
    public var useLoginShell: Bool
    public var isExecutable: @Sendable (String) -> Bool
    private let runner: any ProcessRunning

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidates: [String] = AzureCLILocator.defaultCandidates,
        useLoginShell: Bool = true,
        runner: any ProcessRunning = ProcessRunner(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        override = environment["ADO_PULSE_AZ"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        self.candidates = candidates
        self.useLoginShell = useLoginShell
        self.runner = runner
        self.isExecutable = isExecutable
    }

    public static let defaultCandidates: [String] = [
        "/opt/homebrew/bin/az",
        "/usr/local/bin/az",
        "/usr/bin/az",
        "/opt/local/bin/az",
        NSString(string: "~/.local/bin/az").expandingTildeInPath,
    ]

    public func locate() async -> URL? {
        if let override, isExecutable(override) {
            return URL(fileURLWithPath: override)
        }
        if let found = candidates.first(where: isExecutable) {
            return URL(fileURLWithPath: found)
        }
        guard useLoginShell else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard let result = try? await runner.run(
            URL(fileURLWithPath: shell), arguments: ["-l", "-c", "command -v az"], environment: nil, timeout: 15
        ), result.status == 0 else { return nil }
        let path = String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        guard let path, isExecutable(path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

public struct ProcessResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult
}

/// Runs a program to completion and collects its output, within the timeout. The program runs in a process group
/// of its own, so at the timeout it ends with everything it started. Once it exits, output that something it started
/// keeps open (a background upload, say) is waited for only briefly, and that is ended too.
public struct ProcessRunner: ProcessRunning {
    /// How long to wait for the output to end after the program exits.
    var drainTime: TimeInterval = 0.5

    public init() {}

    public func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> ProcessResult {
        let process = try SpawnedProcess(executable: executable, arguments: arguments, environment: environment)
        return await process.result(timeout: timeout, drainTime: drainTime)
    }
}

/// One run of a program, its output read as it comes. Everything after `init` happens on `queue`.
private final class SpawnedProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ADOPulse.ProcessRunner")
    private let pid: pid_t
    private let descriptors: [Int32]
    private var output = [Data(), Data()]
    private var reading: [DispatchSourceRead] = []
    private var exitWatch: DispatchSourceProcess?
    private var status: Int32?
    private var continuation: CheckedContinuation<ProcessResult, Never>?

    init(executable: URL, arguments: [String], environment: [String: String]?) throws {
        var stdout: [Int32] = [-1, -1]
        var stderr: [Int32] = [-1, -1]
        guard pipe(&stdout) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard pipe(&stderr) == 0 else {
            stdout.forEach { close($0) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderr[1], 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A process group of its own, to end it with whatever it starts; and no open descriptors but those three.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let variables = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            variables.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, argv, variables)
        close(stdout[1])
        close(stderr[1])
        guard spawned == 0 else {
            close(stdout[0])
            close(stderr[0])
            throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO)
        }
        self.pid = pid
        descriptors = [stdout[0], stderr[0]]
    }

    func result(timeout: TimeInterval, drainTime: TimeInterval) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            queue.async { self.start(continuation, timeout: timeout, drainTime: drainTime) }
        }
    }

    private func start(_ continuation: CheckedContinuation<ProcessResult, Never>, timeout: TimeInterval, drainTime: TimeInterval) {
        self.continuation = continuation
        for (index, descriptor) in descriptors.enumerated() {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { self.read(descriptor, into: index, source: source) }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            reading.append(source)
        }
        let exitWatch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitWatch.setEventHandler { self.reap(drainTime: drainTime) }
        exitWatch.resume()
        self.exitWatch = exitWatch
        // It may have exited before the watch began.
        reap(drainTime: drainTime)

        // At the timeout, ask it (and whatever it started) to stop, then make it; and stop waiting soon after either way.
        queue.asyncAfter(deadline: .now() + timeout) {
            guard self.continuation != nil else { return }
            killpg(self.pid, SIGTERM)
            self.queue.asyncAfter(deadline: .now() + 1) {
                guard self.continuation != nil else { return }
                killpg(self.pid, SIGKILL)
                self.queue.asyncAfter(deadline: .now() + 2) { self.stopReading(status: SIGKILL) }
            }
        }
    }

    private func read(_ descriptor: Int32, into index: Int, source: DispatchSourceRead) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !source.isCancelled {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                output[index].append(contentsOf: buffer[0..<count])
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                return
            } else {
                // The end of the output (or an error reading it).
                source.cancel()
                finishIfDone()
                return
            }
        }
    }

    private func reap(drainTime: TimeInterval) {
        var raw: Int32 = 0
        guard waitpid(pid, &raw, WNOHANG) == pid else { return }
        exitWatch?.cancel()
        // Reaped after giving up on it: the result is already out.
        guard status == nil else { return }
        // Exited normally: its exit code. Ended by a signal: the signal, as Foundation's Process reports it.
        let signal = raw & 0x7f
        status = signal == 0 ? (raw >> 8) & 0xff : signal
        finishIfDone()
        // Whatever still holds its output open is something it started.
        queue.asyncAfter(deadline: .now() + drainTime) { self.stopReading(status: nil) }
    }

    /// Stops waiting for output that's still open, and ends whatever in its process group holds it.
    private func stopReading(status fallback: Int32?) {
        guard continuation != nil else { return }
        killpg(pid, SIGKILL)
        for source in reading where !source.isCancelled { source.cancel() }
        if status == nil { status = fallback }
        finishIfDone()
    }

    private func finishIfDone() {
        guard let continuation, let status, reading.allSatisfy(\.isCancelled) else { return }
        self.continuation = nil
        continuation.resume(returning: ProcessResult(status: status, stdout: output[0], stderr: output[1]))
    }
}
