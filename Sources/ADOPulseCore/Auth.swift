import Foundation

/// A bearer token for Azure DevOps.
public struct AccessToken: Sendable, Equatable {
    public var value: String
    public var expiresOn: Date

    public init(value: String, expiresOn: Date) {
        self.value = value
        self.expiresOn = expiresOn
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
        return AccessToken(value: output.accessToken, expiresOn: expiry)
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

/// Runs a program to completion and collects its output, ending it if it runs past the timeout.
public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let environment { process.environment = environment }
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain both pipes while it runs, so a chatty program can't block on a full pipe.
                let output = Collected()
                let group = DispatchGroup()
                for (pipe, isError) in [(stdout, false), (stderr, true)] {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        output.set(data, isError: isError)
                        group.leave()
                    }
                }
                let running = UncheckedBox(process)
                let deadline = DispatchWorkItem {
                    if running.value.isRunning { running.value.terminate() }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
                process.waitUntilExit()
                deadline.cancel()
                group.wait()
                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus, stdout: output.stdout, stderr: output.stderr
                ))
            }
        }
    }
}

/// Output gathered on two reader threads; `DispatchGroup.wait()` orders the reads after the writes.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func set(_ data: Data, isError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isError { err = data } else { out = data }
    }

    var stdout: Data { lock.withLock { out } }
    var stderr: Data { lock.withLock { err } }
}

/// Hands a non-Sendable value to a closure on another thread when access is otherwise synchronized.
final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
