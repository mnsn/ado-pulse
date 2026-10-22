import Foundation
import SQLite3
import Testing
@testable import ADOPulse
@testable import ADOPulseCore

/// The command-line modes and `--render` print or save what they read, so they run only with the permissions of the
/// app that started ADO Pulse: never with its own Full Disk Access, which whoever started it would get the use of.
@Suite struct CommandLineAccessTests {
    @Test func refusesEveryModeWithItsOwnPermissions() {
        for mode in CLI.modes {
            for arguments in [[mode], [mode, "--demo"], ["--demo", mode, "out"]] {
                // `open -n -g --stdout out.txt "ADO Pulse.app" --args --chats`, or a program that disclaimed it.
                #expect(CLI.refusal(arguments, attribution: .itself)?.contains("Started as an app") == true, "\(arguments)")
                // From a shell, such as Terminal's, with its permissions.
                #expect(CLI.refusal(arguments, attribution: .caller) == nil, "\(arguments)")
            }
        }
        // The app itself still runs, with your pull requests or the made-up ones, and so does --help.
        for arguments in [[], ["--demo"], ["--help"], ["-h"]] {
            #expect(CLI.refusal(arguments, attribution: .itself) == nil, "\(arguments)")
        }
    }

    @Test func runsNoModeWithItsOwnPermissions() {
        // Made-up data only, so that if a mode did run, it would only print that.
        #expect(CLI.run(["--chats", "--demo"], attribution: .itself) == 1)
        #expect(CLI.run(["--json", "--demo"], attribution: .itself) == 1)
        #expect(CLI.run(["--render", "pictures", "--demo"], attribution: .itself) == 1)
    }

    /// The control, with what macOS says about real programs. The built `ADOPulse`, started responsible for itself as
    /// LaunchServices starts an app, refuses `--chats`, so it reads neither Notification Center nor the copy its
    /// environment names, and `--render` draws nothing. Started plainly, as from a shell, it lists that copy's made-up
    /// link, and the demo works.
    @Test(.timeLimit(.minutes(2)))
    func theBuiltAppRefusesWhenItsResponsibleForItself() async throws {
        let binary = try Self.builtApp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ADOPulseTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("db2/db")
        try Self.makeNotificationDatabase(at: database)
        let environment = [
            "PATH": "/usr/bin:/bin", "HOME": folder.path, "CFFIXED_USER_HOME": folder.path,
            NotificationCenterDatabase.overrideVariable: database.path,
        ]
        let own = ProcessRunner()
        var plain = ProcessRunner()
        plain.disclaim = { _ in }

        let refused = try await own.run(binary, arguments: ["--chats"], environment: environment, timeout: 60)
        #expect(refused.status == 1)
        #expect(refused.stdout.isEmpty)
        #expect(String(decoding: refused.stderr, as: UTF8.self).contains("Started as an app"))

        let pictures = folder.appendingPathComponent("pictures")
        let drawn = try await own.run(binary, arguments: ["--render", pictures.path, "--demo"], environment: environment, timeout: 60)
        #expect(drawn.status == 1)
        #expect(!FileManager.default.fileExists(atPath: pictures.path))

        let listed = try await plain.run(binary, arguments: ["--chats"], environment: environment, timeout: 60)
        let output = String(decoding: listed.stdout, as: UTF8.self)
        #expect(listed.status == 0, "\(String(decoding: listed.stderr, as: UTF8.self))")
        #expect(output.contains("Dana Whitfield"))
        #expect(output.contains("contoso/7"))

        let demo = try await plain.run(binary, arguments: ["--json", "--demo"], environment: environment, timeout: 60)
        #expect(demo.status == 0)
        #expect(String(decoding: demo.stdout, as: UTF8.self).contains("\"needsYou\""))
    }

    /// The `ADOPulse` built with these tests, beside their bundle.
    static func builtApp() throws -> URL {
        let binary = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ADOPulse")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "Build ADOPulse first (swift build): \(binary.path)")
        return binary
    }

    /// A copy of Notification Center's database with one made-up notification: Dana sends a link in Slack.
    static func makeNotificationDatabase(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sent = Date().addingTimeInterval(-600).timeIntervalSinceReferenceDate
        let request: [String: Any] = [
            "titl": "Dana Whitfield", "iden": "made-up-1",
            "body": "Could you look at https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/7 today?",
        ]
        let record: [String: Any] = ["app": "com.tinyspeck.slackmacgap", "date": sent, "req": request]
        let data = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(handle) }
        let statements = """
            CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR);
            CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, request_date REAL,
                                 delivered_date REAL);
            INSERT INTO app (app_id, identifier) VALUES (1, 'com.tinyspeck.slackmacgap');
            INSERT INTO record (app_id, data, request_date, delivered_date) VALUES (1, X'\(hex)', \(sent), \(sent));
            """
        guard sqlite3_exec(handle, statements, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
}

private final class BundleMarker {}
