import Foundation
import os

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

/// Keeps the programs ADO Pulse starts from using its privacy permissions.
///
/// macOS attributes a program to the app that started it, its "responsible process", and lets it use that app's
/// privacy permissions. Once you give ADO Pulse Full Disk Access, for pull requests sent in chats, the programs it
/// starts would have it too: the Azure CLI, a Python program in a folder you can write to; your login shell, which
/// ADO Pulse asks where `az` is, and which runs your shell's startup files; and whatever those run. Anything running
/// as you can change the CLI, its Python files and those startup files. So every program ADO Pulse starts disclaims
/// that: it's responsible for itself, and gets only the permissions macOS gave it, as Chromium and LLDB do with the
/// programs they start. The call is private to macOS, so it's looked up when it's needed; without it, nothing is
/// started.
public enum Responsibility {
    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Bool) -> Int32
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
    }

    /// Makes a program started with these attributes responsible for itself.
    static func disclaim(_ attributes: inout posix_spawnattr_t?) throws {
        try disclaim(&attributes, with: "responsibility_spawnattrs_setdisclaim")
    }

    /// The same, with the call looked up by its name, which tests change.
    static func disclaim(_ attributes: inout posix_spawnattr_t?, with name: String) throws {
        guard let address = symbol(name) else { throw ProcessRunnerError.cantDisclaim }
        guard unsafeBitCast(address, to: Disclaim.self)(&attributes, true) == 0 else { throw ProcessRunnerError.cantDisclaim }
    }

    /// The process macOS holds responsible for `pid`, whose permissions it may use, or nil if it can't tell.
    public static func responsibleProcess(for pid: pid_t) -> pid_t? {
        guard let address = symbol("responsibility_get_pid_responsible_for_pid") else { return nil }
        let responsible = unsafeBitCast(address, to: ResponsiblePID.self)(pid)
        return responsible > 0 ? responsible : nil
    }

    /// Logs a fault if a program ADO Pulse started is attributed to another process after all.
    static func verify(_ pid: pid_t, executable: URL) {
        guard let responsible = responsibleProcess(for: pid), responsible != pid else { return }
        let name = executable.lastPathComponent
        Logger(subsystem: "com.asaf.ADOPulse", category: "app").fault(
            "\(name, privacy: .public) is attributed to process \(responsible), and may use its privacy permissions"
        )
    }
}

public enum ProcessRunnerError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// macOS doesn't offer the call that keeps a program from using ADO Pulse's permissions, or it failed.
    case cantDisclaim

    public var description: String {
        "ADO Pulse can't start programs on this version of macOS without giving them its permissions, so it doesn't."
    }

    public var errorDescription: String? { description }
}

/// Runs a program to completion and collects its output, within the timeout. The program runs in a process group
/// of its own, so at the timeout it ends with everything it started. Once it exits, output that something it started
/// keeps open (a background upload, say) is waited for only briefly, and that is ended too. Like every program ADO
/// Pulse starts, it's responsible for itself (see `Responsibility`).
public struct ProcessRunner: ProcessRunning {
    /// How long to wait for the output to end after the program exits.
    var drainTime: TimeInterval = 0.5
    /// Makes the program responsible for itself. Tests replace it, to see what happens without that.
    var disclaim: @Sendable (inout posix_spawnattr_t?) throws -> Void = { try Responsibility.disclaim(&$0) }

    public init() {}

    public func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> ProcessResult {
        let process = try SpawnedProcess(executable: executable, arguments: arguments, environment: environment, disclaim: disclaim)
        return await process.result(timeout: timeout, drainTime: drainTime)
    }

    /// Starts a program that outlives ADO Pulse, such as the one that opens it again after it quits: in a session of
    /// its own, with no input or output, and responsible for itself. It isn't waited for. Returns its process ID.
    @discardableResult
    public static func launch(_ executable: URL, arguments: [String]) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        try Responsibility.disclaim(&attributes)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let variables = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            variables.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, argv, variables)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }
        Responsibility.verify(pid, executable: executable)
        return pid
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
    private var reaped = false
    private var continuation: CheckedContinuation<ProcessResult, Never>?

    init(
        executable: URL, arguments: [String], environment: [String: String]?,
        disclaim: (inout posix_spawnattr_t?) throws -> Void
    ) throws {
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
        // Responsible for itself, so it doesn't get ADO Pulse's permissions; or it isn't started.
        do {
            try disclaim(&attributes)
        } catch {
            (stdout + stderr).forEach { close($0) }
            throw error
        }

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
        Responsibility.verify(pid, executable: executable)
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
        exitWatch.setEventHandler { self.reap(drainTime: drainTime, exited: true) }
        exitWatch.resume()
        self.exitWatch = exitWatch
        // It may have exited before the watch began.
        reap(drainTime: drainTime, exited: false)

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

    /// Collects its exit status. Once told it `exited`, it waits for that: the exit can be reported a moment before
    /// the status can be collected, and isn't reported again.
    private func reap(drainTime: TimeInterval, exited: Bool) {
        guard !reaped else { return }
        var raw: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &raw, exited ? 0 : WNOHANG)
        } while result == -1 && errno == EINTR
        guard result == pid else { return }
        reaped = true
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
