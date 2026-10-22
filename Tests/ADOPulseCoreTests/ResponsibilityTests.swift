import Foundation
import Testing
@testable import ADOPulseCore

/// Started from an app, a program is attributed to it, and may use its privacy permissions, such as the Full Disk
/// Access you give ADO Pulse. So every program ADO Pulse starts is responsible for itself.
@Suite struct ResponsibilityTests {
    /// What `osascript` reports about itself: its process ID, then the process macOS holds responsible for it.
    private static let selfReport = """
        ObjC.bindFunction("responsibility_get_pid_responsible_for_pid", ["int", ["int"]]);
        ObjC.bindFunction("getpid", ["int", []]);
        var pid = $.getpid(); pid + " " + $.responsibility_get_pid_responsible_for_pid(pid)
        """

    /// Runs `osascript` with the runner: its process ID, and the process responsible for it.
    private func report(with runner: ProcessRunner) async throws -> (pid: pid_t, responsible: pid_t) {
        let result = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-l", "JavaScript", "-e", Self.selfReport],
            environment: nil, timeout: 30
        )
        let numbers = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: " ")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        try #require(numbers.count == 2, "osascript printed \(String(decoding: result.stdout + result.stderr, as: UTF8.self))")
        return (numbers[0], numbers[1])
    }

    @Test(.timeLimit(.minutes(1)))
    func startsProgramsResponsibleForThemselves() async throws {
        let started = try await report(with: ProcessRunner())
        #expect(started.responsible == started.pid)

        // Without that, the same program would be attributed to what this test process is attributed to, so the check
        // above tells. Where this process is responsible for itself, it can't: some hosts start every program that
        // way, and then everything those start is too.
        if let host = Responsibility.responsibleProcess(for: getpid()), host != getpid() {
            var plain = ProcessRunner()
            plain.disclaim = { _ in }
            let attributed = try await report(with: plain)
            #expect(attributed.responsible == host)
        }
    }

    @Test func startsNothingItCantMakeResponsibleForItself() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "ADOPulse-\(UUID().uuidString)")
        var runner = ProcessRunner()
        runner.disclaim = { _ in throw ProcessRunnerError.cantDisclaim }
        await #expect(throws: ProcessRunnerError.cantDisclaim) {
            try await runner.run(URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path], environment: nil, timeout: 10)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        // And signing in says why.
        let provider = AzureCLITokenProvider(
            locator: AzureCLILocator(environment: [:], candidates: ["/usr/bin/touch"], useLoginShell: false), runner: runner
        )
        await #expect(throws: AuthError.failed(
            "Couldn't run the Azure CLI: ADO Pulse can't start programs on this version of macOS without giving them its "
                + "permissions, so it doesn't."
        )) {
            try await provider.token()
        }
    }

    @Test func findsTheCallsThatKeepProgramsFromUsingItsPermissions() throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        try Responsibility.disclaim(&attributes)
        #expect(Responsibility.responsibleProcess(for: getpid()) != nil)
        // Were the call missing, nothing would be started.
        #expect(throws: ProcessRunnerError.cantDisclaim) {
            try Responsibility.disclaim(&attributes, with: "responsibility_spawnattrs_setdisclaim_missing")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func launchesProgramsResponsibleForThemselves() async throws {
        // A program that runs while a file is there, to be asked about meanwhile.
        let hold = FileManager.default.temporaryDirectory.appending(path: "ADOPulse-\(UUID().uuidString)")
        try Data().write(to: hold)
        defer { try? FileManager.default.removeItem(at: hold) }
        let pid = try ProcessRunner.launch(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "while [ -e \"$0\" ]; do /bin/sleep 0.05; done", hold.path]
        )
        #expect(Responsibility.responsibleProcess(for: pid) == pid)

        try FileManager.default.removeItem(at: hold)
        var status: Int32 = 0
        var reaped = false
        for _ in 0..<200 where !reaped {
            reaped = waitpid(pid, &status, WNOHANG) == pid
            if !reaped { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(reaped)
    }

    /// Nothing but `ProcessRunner` starts programs, so none is started with ADO Pulse's permissions. (Opening an app,
    /// a URL or a file through LaunchServices, with `NSWorkspace`, makes that app responsible for itself.)
    @Test func nothingElseStartsPrograms() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let starting = try NSRegularExpression(pattern: [
            #"\bposix_spawnp?\("#,
            #"(?<!\w)Process(\(|\.run\(|\.launchedProcess\()"#,
            #"\bNSTask\b"#,
            #"\bNSUser\w*Task\b"#,
            #"\b(NSAppleScript|OSAScript)\b"#,
            #"(?<![\w.])(system|popen|fork|vfork|execv|execve|execvp|execl|execle|execlp)\("#,
        ].joined(separator: "|"))
        func starts(_ line: String) -> Bool {
            starting.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }

        var found: [String] = []
        var files = 0
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            files += 1
            guard file.lastPathComponent != "ProcessRunner.swift" else { continue }
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && starts(line) {
                found.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(files > 20)
        #expect(found.isEmpty, "Start programs with ProcessRunner, not: \(found.joined(separator: "; "))")

        // What it looks for, and what it doesn't.
        for line in ["let process = Process()", "try Foundation.Process.run(url, arguments: [])", "posix_spawn(&pid, path, nil, nil, argv, nil)",
                     "system(\"ls\")", "NSAppleScript(source: script)", "execv(path, argv)"] {
            #expect(starts(line), "\(line)")
        }
        for line in [".font(.system(size: 11))", "ProcessInfo.processInfo.environment", "SpawnedProcess(executable: url)",
                     "DispatchSource.makeProcessSource(identifier: pid)", "NSWorkspace.shared.open(url)"] {
            #expect(!starts(line), "\(line)")
        }
    }
}
