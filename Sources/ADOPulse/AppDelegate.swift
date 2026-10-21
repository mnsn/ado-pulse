import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mode: PRStore.Mode
    private let settings: AppSettings
    private let loginItem = LoginItem()
    private let notifier = Notifier()
    private lazy var store = PRStore(settings: settings, notifier: notifier, mode: mode)
    private var statusItem: StatusItemController?
    private var widget: DesktopWidgetController?

    init(mode: PRStore.Mode) {
        self.mode = mode
        if mode == .demo, let defaults = UserDefaults(suiteName: "ADOPulse.demo") {
            // The demo never touches your settings or what you've seen.
            defaults.removePersistentDomain(forName: "ADOPulse.demo")
            settings = AppSettings(defaults: defaults)
        } else {
            settings = AppSettings()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar app has no visible windows most of the time; don't let macOS reclaim it.
        ProcessInfo.processInfo.disableAutomaticTermination("Shows your pull requests")
        Log.app.info("Launched from \(Bundle.main.bundlePath, privacy: .public)\(self.mode == .demo ? " with demo data" : "", privacy: .public)")
        statusItem = StatusItemController(store: store, settings: settings, loginItem: loginItem)
        widget = DesktopWidgetController(store: store, settings: settings, loginItem: loginItem)
        notifier.onOpen = { [weak self] key, url in
            guard let self else { return }
            if let url {
                self.store.openFromNotification(key: key, url: url)
            } else {
                self.statusItem?.showPopover()
            }
        }
        store.start()
    }

    /// Launching the app again (Finder, Spotlight, `open`) shows the list.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.showPopover()
        return false
    }
}
