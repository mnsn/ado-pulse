import AppKit

// `ADOPulse --dump | --json | --watch | --orgs | --help` work from a terminal without starting the UI.
if let code = CLI.run(Array(CommandLine.arguments.dropFirst())) {
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

    let app = NSApplication.shared
    let delegate = AppDelegate(mode: demo ? .demo : .live)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
