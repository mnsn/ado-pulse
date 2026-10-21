import ADOPulseCore
import AppKit
import Combine
import SwiftUI

/// Menu-bar item showing colored counts, with the pull request list in a popover.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: PRStore
    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []

    /// The groups counted in the menu bar: what to act on. Waiting and Done only show in the panel.
    static func shownGroups(showToReview: Bool) -> [PRGroup] {
        showToReview ? [.needsYou, .failing, .ready, .toReview] : [.needsYou, .failing, .ready]
    }

    init(store: PRStore, settings: AppSettings, loginItem: LoginItem) {
        self.store = store
        self.settings = settings
        super.init()

        let host = NSHostingController(
            rootView: MenuPanelView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(loginItem)
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem.autosaveName = "ADOPulseStatusItem"

        render()
        store.$counts.removeDuplicates().map { _ in () }
            .merge(with: settings.$showToReview.removeDuplicates().map { _ in () })
            .merge(with: store.$problem.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.render() } }
            .store(in: &cancellables)

        // Opening a pull request hands focus to the browser; don't leave the list hanging open.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.popover.performClose(nil) } }
            .store(in: &cancellables)
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        store.refreshIfStale()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let groups = Self.shownGroups(showToReview: settings.showToReview)
        Self.configure(button, for: store.counts, groups: groups, needsSignIn: store.problem?.needsSignIn == true)
        let spoken = groups.filter { store.counts[$0] > 0 }.map { "\(store.counts[$0]) \($0.countLabel)" }
        if store.problem?.needsSignIn == true {
            button.toolTip = "ADO Pulse: sign in to see your pull requests"
        } else {
            button.toolTip = spoken.isEmpty ? "ADO Pulse: nothing needs you" : "ADO Pulse: " + spoken.joined(separator: ", ")
        }
        button.setAccessibilityLabel(button.toolTip)
    }

    /// Sets the glyph and the colored counts. `--render` sets up the button in the README's menu-bar picture
    /// here too, so the picture can't drift from the real item.
    static func configure(_ button: NSButton, for counts: GroupCounts, groups: [PRGroup], needsSignIn: Bool = false) {
        let glyph = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "ADO Pulse")
        glyph?.isTemplate = true
        button.image = glyph
        let title = needsSignIn ? signInTitle() : Self.title(for: counts, groups: groups)
        button.attributedTitle = title
        button.imagePosition = title.length == 0 ? .imageOnly : .imageLeading
    }

    /// The counts after the glyph: each non-zero group's symbol in its color, then the number.
    private static func title(for counts: GroupCounts, groups: [PRGroup]) -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        for group in groups where counts[group] > 0 {
            title.append(NSAttributedString(string: " "))
            title.append(symbol(group.symbol, color: group.nsColor, font: font))
            title.append(NSAttributedString(
                string: "\u{2009}\(counts[group])",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .medium),
                             .foregroundColor: NSColor.labelColor]
            ))
        }
        return title
    }

    /// A small orange person badge while you need to sign in.
    private static func signInTitle() -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString(string: " ")
        title.append(symbol("person.crop.circle.badge.exclamationmark.fill", color: .systemOrange, font: font))
        return title
    }

    private static func symbol(_ name: String, color: NSColor, font: NSFont) -> NSAttributedString {
        // Monochrome keeps the check and the cross cut out; one palette color fills them in.
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize - 2, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            .applying(.preferringMonochrome())
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0, y: (font.capHeight - image.size.height) / 2,
            width: image.size.width, height: image.size.height
        )
        return NSAttributedString(attachment: attachment)
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        store.panelDidOpen()
    }

    func popoverDidClose(_ notification: Notification) {
        store.panelDidClose()
    }
}
