import ADOPulseCore
import AppKit
import Combine
import SwiftUI

/// The window that walks you through granting Full Disk Access, for pull requests sent in chats. It opens
/// when you turn that on and ADO Pulse can't read Notification Center, and checks for access every two
/// seconds while it's open.
@MainActor
final class ChatAccessController: NSObject, ObservableObject, NSWindowDelegate {
    private let store: PRStore
    private var window: NSWindow?

    /// Whether this is the app bundle, rather than a binary run from Terminal (whose Full Disk Access is
    /// then Terminal's).
    let isBundled = Bundle.main.bundleIdentifier == AppSettings.domain

    /// Whether macOS checks ADO Pulse's own Full Disk Access: it was started as an app, not from a shell.
    var usesOwnAccess: Bool { isBundled && store.chats.usesOwnAccess }

    /// The folder the app is in, as you'd type it in an Open panel: `~/Applications` after `make install`.
    var appFolder: String {
        (Bundle.main.bundleURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    init(store: PRStore) {
        self.store = store
        super.init()
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: ChatAccessView()
                .environmentObject(store)
                .environmentObject(store.settings)
                .environmentObject(self))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "ADO Pulse"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        store.setWaitingForChatAccess(true)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            store.setWaitingForChatAccess(false)
        }
    }

    /// System Settings › Privacy & Security › Full Disk Access.
    static func openPrivacySettings() {
        let panes = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for pane in panes {
            if let url = URL(string: pane), NSWorkspace.shared.open(url) { return }
        }
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Quits and opens the app again, once this process has exited, for when macOS only applies access
    /// after a restart. The helper that waits is responsible for itself, like every program ADO Pulse starts.
    func relaunch() {
        guard isBundled else { return }
        do {
            try ProcessRunner.launch(URL(fileURLWithPath: "/bin/sh"), arguments: [
                "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier),
            ])
            NSApp.terminate(nil)
        } catch {
            Log.app.error("Couldn't relaunch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Turns the feature off again, from the window.
    func turnOff() {
        store.settings.chatLinksEnabled = false
        close()
    }
}

struct ChatAccessView: View {
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var controller: ChatAccessController

    private var granted: Bool { store.chatAccess == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AppIconView(isBundled: controller.isBundled)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Allow Full Disk Access")
                        .font(.title2.weight(.semibold))
                    Text("So ADO Pulse can find the pull requests people send you")
                        .foregroundStyle(.secondary)
                }
            }

            Text("ADO Pulse looks for links to Azure DevOps pull requests in the notifications that macOS keeps in Notification Center, from Teams, Slack, Outlook or any other app. macOS protects that database, so ADO Pulse needs Full Disk Access to read it. It only reads it, and it keeps only the links it finds, with who sent them, in which app and when, in memory: never the messages, and nothing leaves your Mac."
                + (controller.usesOwnAccess ? " Turning this off removes its Full Disk Access again." : ""))
                .fixedSize(horizontal: false, vertical: true)

            if settings.chatAccessWasGranted && !granted {
                Label("ADO Pulse had access before. That happens when it's rebuilt with another signature: remove ADO Pulse from the list with −, then add it again. If it still has no access, run `tccutil reset SystemPolicyAllFiles \(AppSettings.domain)` in Terminal, then add it again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if controller.usesOwnAccess {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Click **Open Privacy Settings**. macOS doesn't add apps to that list by itself, so ADO Pulse isn't there yet.")
                    step(2, "Click **+** under the list and choose **ADO Pulse** in **\(controller.appFolder)** (press ⌘⇧G to type the folder). Or click **Show in Finder** and drag ADO Pulse into the list.")
                    step(3, "Turn on its switch. If macOS offers to, choose **Quit & Reopen**.")
                }
            } else {
                Text("You're running ADO Pulse from Terminal, so macOS checks Terminal's access instead: give **Terminal** Full Disk Access, then run ADO Pulse again.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Open Privacy Settings") { ChatAccessController.openPrivacySettings() }
                    .keyboardShortcut(.defaultAction)
                if controller.isBundled {
                    Button("Show in Finder") { controller.showInFinder() }
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 8) {
                if granted {
                    Label("Done. ADO Pulse can see the pull requests people send you now.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Close") { controller.close() }
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for access…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Turn Off") { controller.turnOff() }
                        .help("Stop looking for pull requests sent in chats")
                    if controller.isBundled {
                        Button("Quit & Reopen") { controller.relaunch() }
                            .help("Use this if you turned access on and ADO Pulse still waits")
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The app's icon, which you can drag into the Full Disk Access list.
struct AppIconView: View {
    let isBundled: Bool

    var body: some View {
        let icon = Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .frame(width: 64, height: 64)
        if isBundled {
            icon
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .help("Drag this into the Full Disk Access list")
        } else {
            icon
        }
    }
}
