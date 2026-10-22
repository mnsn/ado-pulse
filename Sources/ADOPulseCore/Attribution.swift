import Darwin
import Foundation

/// Whose privacy permissions ADO Pulse runs with, Full Disk Access included.
///
/// macOS attributes a process to the app it holds responsible (see `Responsibility`), and checks privacy permissions
/// against that app's executable. Run from a shell, ADO Pulse is attributed to the app the shell runs in, such as
/// Terminal, and has only that app's permissions. Started by LaunchServices, as an app (Finder, a login item,
/// `open`), or by a program that disclaimed it, it's attributed to itself, and has its own: the Full Disk Access you
/// gave ADO Pulse. Then whoever started it chose its arguments and environment, and may read its output
/// (`open --stdout`), so none of them may decide what it reads or where that goes.
public enum Attribution: Sendable, Equatable {
    /// Attributed to the app that started it, such as Terminal: it has that app's permissions.
    case caller
    /// Attributed to itself, with ADO Pulse's own permissions; or macOS can't tell, which counts the same.
    case itself

    /// The process macOS holds responsible for another, as it says.
    public struct Responsible: Sendable, Equatable {
        public var pid: pid_t
        /// The executable that privacy permissions are checked against; nil when macOS doesn't say.
        public var path: String?

        public init(pid: pid_t, path: String?) {
            self.pid = pid
            self.path = path
        }
    }

    /// - Parameters:
    ///   - pid: the process, and `executable`, its executable.
    ///   - responsible: the process macOS holds responsible for it; nil when macOS can't tell.
    public init(pid: pid_t, executable: String?, responsible: Responsible?) {
        guard let responsible else {
            self = .itself
            return
        }
        // The executable decides, as it does for privacy permissions: a process can be its own responsible process
        // and still be attributed to another app, as the GitHub Copilot app's agents are.
        if let path = responsible.path, let executable {
            self = Self.isSameFile(path, executable) ? .itself : .caller
        } else {
            self = responsible.pid == pid ? .itself : .caller
        }
    }

    /// This process.
    public static let current = Attribution(
        pid: getpid(), executable: executablePath(of: getpid()), responsible: responsibleProcess(for: getpid())
    )

    /// The environment variables that may point ADO Pulse at other data than yours, such as a copy of Notification
    /// Center's database: all of them while it has the permissions of the app that started it, none while it has its
    /// own. Read them through here.
    public static var environment: [String: String] {
        current.environment(ProcessInfo.processInfo.environment)
    }

    public func environment(_ variables: [String: String]) -> [String: String] {
        self == .caller ? variables : [:]
    }

    private typealias GetResponsible = @convention(c) (
        pid_t, UnsafeMutablePointer<pid_t>?, UnsafeMutablePointer<UInt64>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<CChar>?
    ) -> Int32
    private typealias GetResponsiblePID = @convention(c) (pid_t) -> pid_t

    /// What macOS says about who's responsible for `pid`: the process and its executable, or with an older macOS,
    /// the process only. Both calls are private to macOS, so they're looked up when needed.
    static func responsibleProcess(for pid: pid_t) -> Responsible? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        if let address = dlsym(rtldDefault, "responsibility_get_responsible_for_pid") {
            var responsible: pid_t = 0
            var uniqueID: UInt64 = 0
            var length = Int(MAXPATHLEN)
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
            guard unsafeBitCast(address, to: GetResponsible.self)(pid, &responsible, &uniqueID, &length, &path) == 0,
                  responsible > 0
            else { return nil }
            let executable = string(path)
            return Responsible(pid: responsible, path: executable.isEmpty ? nil : executable)
        }
        guard let address = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
        let responsible = unsafeBitCast(address, to: GetResponsiblePID.self)(pid)
        return responsible > 0 ? Responsible(pid: responsible, path: nil) : nil
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(buffer)
    }

    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Errs toward "the same", which only makes ADO Pulse more careful.
    static func isSameFile(_ a: String, _ b: String) -> Bool {
        if a == b || URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path {
            return true
        }
        var one = stat()
        var other = stat()
        guard stat(a, &one) == 0, stat(b, &other) == 0 else { return false }
        return one.st_dev == other.st_dev && one.st_ino == other.st_ino
    }
}
