import Foundation
import Synchronization

/// Watches Notification Center's database for pull request links in new notifications. It checks for
/// access, reads every stored notification (a short read-only read), and reads again whenever the
/// database's write-ahead log changes (kqueue, debounced) and once a minute in case a change was missed.
///
/// All mutable state is confined to `queue`. `onChange` is called on the delivery queue, and never once `stop()`
/// has returned there, even for a read that was under way.
public final class ChatLinkMonitor: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var access: AccessStatus
        /// Every link in the stored notifications, oldest first.
        public var links: [ChatLink]
        /// Why the database couldn't be read, when access was granted.
        public var problem: String?

        public init(access: AccessStatus, links: [ChatLink] = [], problem: String? = nil) {
            self.access = access
            self.links = links
            self.problem = problem
        }
    }

    public typealias ChangeHandler = @Sendable (Snapshot) -> Void

    public let database: URL
    private let queue = DispatchQueue(label: "ADOPulse.ChatLinkMonitor", qos: .utility)
    private let delivery: DispatchQueue
    private let scan: @Sendable (URL) -> Snapshot
    private let onChange: ChangeHandler
    /// Set by `stop()` at once, rather than on `queue`, so what a read in progress finds isn't delivered.
    private let stopped = Mutex(false)
    private let debounce: TimeInterval
    private var watcher: FileWriteWatcher?
    private var timer: DispatchSourceTimer?
    private var pendingRead = false
    private var isActive = false
    private var fastAccessChecks = false
    private var lastPublished: Snapshot?

    /// `scan` reads the database; tests replace it.
    public init(
        database: URL = NotificationCenterDatabase.defaultURL(), debounce: TimeInterval = 0.5, deliverOn delivery: DispatchQueue = .main,
        scan: @escaping @Sendable (URL) -> Snapshot = { ChatLinkMonitor.scanOnce(database: $0) }, onChange: @escaping ChangeHandler
    ) {
        self.database = database
        self.debounce = debounce
        self.delivery = delivery
        self.scan = scan
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard !isActive else { return }
            isActive = true
            watcher = FileWriteWatcher(path: database.path + "-wal", queue: queue) { [weak self] in
                self?.scheduleRead()
            }
            read()
            scheduleTimer()
        }
    }

    /// Stops for good. Called on the delivery queue, nothing is delivered after it returns.
    public func stop() {
        stopped.withLock { $0 = true }
        queue.async { [self] in
            isActive = false
            watcher?.cancel()
            watcher = nil
            timer?.cancel()
            timer = nil
            lastPublished = nil
        }
    }

    /// Reads again now, for example when the panel opens.
    public func refresh() {
        queue.async { [self] in
            guard isActive else { return }
            read()
        }
    }

    /// While you're granting Full Disk Access, checks every two seconds instead of every minute.
    public func setWaitingForAccess(_ waiting: Bool) {
        queue.async { [self] in
            guard fastAccessChecks != waiting else { return }
            fastAccessChecks = waiting
            if isActive { scheduleTimer() }
        }
    }

    /// One read, without watching: for the command line and tests.
    public static func scanOnce(database: URL = NotificationCenterDatabase.defaultURL()) -> Snapshot {
        let access = DatabaseAccess.check(database)
        guard access == .granted else { return Snapshot(access: access) }
        do {
            return Snapshot(access: .granted, links: ChatLinkScanner.scan(try NotificationCenterDatabase.load(at: database)))
        } catch {
            return Snapshot(access: .granted, problem: String(describing: error))
        }
    }

    // MARK: Queue-confined

    private func scheduleTimer() {
        timer?.cancel()
        let interval: TimeInterval = fastAccessChecks ? 2 : 60
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive else { return }
            self.read()
        }
        timer.resume()
        self.timer = timer
    }

    private func scheduleRead() {
        guard isActive, !pendingRead else { return }
        pendingRead = true
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            self.pendingRead = false
            guard self.isActive else { return }
            self.read()
        }
    }

    private func read() {
        let snapshot = scan(database)
        if snapshot.access == .granted {
            // The log may have been replaced (a checkpoint, Notification Center restarting).
            watcher?.rearm()
        }
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        delivery.async { [self] in
            // Stopped since this read began, when the feature was turned off: what it found doesn't count.
            guard !stopped.withLock({ $0 }) else { return }
            onChange(snapshot)
        }
    }
}
