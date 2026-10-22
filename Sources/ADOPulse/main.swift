import ADOPulseCore
import AppKit

// Started as an app (Finder, a login item, `open`), or by a program that disclaimed it, ADO Pulse has its own
// permissions, Full Disk Access included, and whoever started it chose its arguments: `-key value` ones would override
// its preferences. So none of them reach it.
let attribution = Attribution.current
if attribution == .itself {
    UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
}

// `ADOPulse --dump | --json | --watch | --orgs | --chats | --help` work from a terminal without starting the UI. They,
// and `--render`, run only with the permissions of the app that started ADO Pulse (see `CLI.refusal`).
if let code = CLI.run(Array(CommandLine.arguments.dropFirst()), attribution: attribution) {
    exit(code)
}

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    let demo = arguments.contains("--demo")
    if let index = arguments.firstIndex(of: "--render") {
        let next = index + 1 < arguments.count ? arguments[index + 1] : nil
        exit(Renderer.run(directory: next.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "render", demo: demo))
    }

    // One instance per user; a second launch (e.g. running the binary again) just exits.
    if let bundleId = Bundle.main.bundleIdentifier {
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .contains(where: { $0.processIdentifier != me }) {
            exit(0)
        }
    }

    // And whoever started it may be reading its output (`open --stdout`), where frameworks may write too, for instance
    // with `OS_ACTIVITY_DT_MODE` set: nothing goes there.
    if attribution == .itself {
        fflush(nil)
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 {
            dup2(null, STDOUT_FILENO)
            dup2(null, STDERR_FILENO)
            close(null)
        }
    }

    let app = NSApplication.shared
    let delegate = AppDelegate(mode: demo ? .demo : .live, attribution: attribution)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
