import Darwin
import Foundation
import Testing
@testable import ADOPulseCore

/// Whose permissions ADO Pulse runs with decides whether its command-line modes run, and whether its environment may
/// point it at other data: these give it what macOS would say in each case, and what it says about real programs.
@Suite struct AttributionTests {
    private let pid: pid_t = 500
    private let adoPulse = "/Applications/ADO Pulse.app/Contents/MacOS/ADOPulse"

    private func attribution(_ responsible: Attribution.Responsible?) -> Attribution {
        Attribution(pid: pid, executable: adoPulse, responsible: responsible)
    }

    @Test func runFromAShellHasThatAppsPermissions() {
        let terminal = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
        #expect(attribution(.init(pid: 400, path: terminal)) == .caller)
        // macOS names the process itself, and the app it's attributed to, as for the GitHub Copilot app's agents.
        #expect(attribution(.init(pid: pid, path: "/Applications/GitHub Copilot.app/Contents/MacOS/github")) == .caller)
    }

    @Test func startedAsAnAppOrDisclaimedHasItsOwn() {
        // LaunchServices (Finder, a login item, `open`), and a program that disclaimed it, look the same.
        #expect(attribution(.init(pid: pid, path: adoPulse)) == .itself)
        // As would a copy of it that it started without disclaiming, which would have its permissions.
        #expect(attribution(.init(pid: 600, path: adoPulse)) == .itself)
    }

    @Test func notKnowingCountsAsItsOwn() {
        #expect(attribution(nil) == .itself)
        #expect(Attribution(pid: pid, executable: nil, responsible: .init(pid: pid, path: adoPulse)) == .itself)
        // An older macOS that names only the process.
        #expect(attribution(.init(pid: pid, path: nil)) == .itself)
        #expect(attribution(.init(pid: 400, path: nil)) == .caller)
    }

    @Test func knowsItsExecutableByAnyPath() throws {
        try withTemporaryDirectory { directory in
            let executable = directory.appendingPathComponent("ADOPulse")
            try Data().write(to: executable)
            let link = directory.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
            #expect(Attribution(pid: pid, executable: executable.path, responsible: .init(pid: pid, path: link.path)) == .itself)
            let hardLink = directory.appendingPathComponent("hard")
            try FileManager.default.linkItem(at: executable, to: hardLink)
            #expect(Attribution(pid: pid, executable: executable.path, responsible: .init(pid: 400, path: hardLink.path)) == .itself)
        }
    }

    @Test func takesOtherDataFromItsEnvironmentOnlyWithTheCallersPermissions() {
        let variables = ["ADO_PULSE_NOTIFICATIONS_DB": "/tmp/db2/db", "HOME": "/Users/someone"]
        #expect(Attribution.caller.environment(variables) == variables)
        #expect(Attribution.itself.environment(variables).isEmpty)
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(NotificationCenterDatabase.defaultURL(environment: Attribution.itself.environment(variables), home: home).path
            == "/Users/someone/Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    @Test func findsYourHomeWhereTheEnvironmentCantMoveIt() {
        // `CFFIXED_USER_HOME`, which `open --env` can set, moves `FileManager`'s home folder, but not this one.
        let home = NotificationCenterDatabase.userHome()
        #expect(home.path.hasPrefix("/"))
        #expect(home.path == String(cString: getpwuid(getuid()).pointee.pw_dir))
    }

    @Test func asksMacOSAboutThisProcess() throws {
        let responsible = try #require(Attribution.responsibleProcess(for: getpid()))
        #expect(responsible.pid > 0)
        #expect(Attribution.executablePath(of: getpid()) != nil)
    }

    /// What macOS says about real programs: one started responsible for itself, as LaunchServices starts an app, is
    /// attributed to itself; one started plainly, as a shell starts it, isn't. This holds wherever the tests run: in
    /// Terminal or on GitHub Actions a plain program is attributed to the app or runner that started the tests, and in
    /// the GitHub Copilot app's agent shells to the Copilot app.
    @Test(.timeLimit(.minutes(1)))
    func tellsAProgramStartedAsAnAppFromOneStartedBySomethingElse() throws {
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        let ownPID = try ProcessRunner.launch(sleep, arguments: ["30"])
        defer { end(ownPID) }
        #expect(attribution(of: ownPID) == .itself)

        let plainPID = try spawnPlainly(sleep, arguments: ["30"])
        defer { end(plainPID) }
        #expect(attribution(of: plainPID) == .caller)
    }

    private func attribution(of pid: pid_t) -> Attribution {
        Attribution(pid: pid, executable: Attribution.executablePath(of: pid), responsible: Attribution.responsibleProcess(for: pid))
    }

    /// Starts a program without disclaiming it, the way a shell does.
    private func spawnPlainly(_ executable: URL, arguments: [String]) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let noVariables: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, nil, argv, noVariables)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }
        return pid
    }

    private func end(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }

    /// Whoever starts ADO Pulse as an app chooses its environment, so the variables that point it at other data are
    /// read only through `Attribution.environment`. Any other read of the environment has to be one of these, each
    /// with its reason, or be added here with one.
    @Test func readsTheEnvironmentOnlyThroughAttribution() throws {
        let allowed: [String: String] = [
            "ADOPulseCore/Attribution.swift": "where the variables are read",
            "ADOPulseCore/ProcessRunner.swift": "hands the environment to programs, which run with their own permissions",
            "ADOPulseCore/Auth.swift": "finds az (ADO_PULSE_AZ, SHELL, PATH), which runs with its own permissions",
        ]
        // Resolved, as the enumerator's paths can be: a checkout under /tmp is under /private/tmp.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources").standardizedFileURL.resolvingSymlinksInPath()
        let reading = try NSRegularExpression(pattern: #"processInfo\.environment|\bgetenv\(|\benviron\b"#)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var readers: Set<String> = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard reading.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
            let path = file.resolvingSymlinksInPath().pathComponents
            try #require(path.starts(with: sources.pathComponents), "\(file.path) isn't in \(sources.path)")
            readers.insert(path.dropFirst(sources.pathComponents.count).joined(separator: "/"))
        }
        #expect(!readers.isEmpty)
        #expect(readers.subtracting(allowed.keys).isEmpty, "Read these through Attribution.environment: \(readers.subtracting(allowed.keys).sorted())")

        // What it looks for, and what it doesn't.
        func reads(_ line: String) -> Bool { reading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
        for line in ["ProcessInfo.processInfo.environment[\"HOME\"]", "getenv(\"HOME\")", "posix_spawn(&pid, path, nil, nil, argv, environ)"] {
            #expect(reads(line), "\(line)")
        }
        for line in ["Attribution.environment", "/// Whoever started it chose its environment.", "environment: [String: String]?"] {
            #expect(!reads(line), "\(line)")
        }
    }
}
