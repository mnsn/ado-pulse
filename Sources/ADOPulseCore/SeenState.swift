import Foundation

/// What you've already seen. Azure DevOps has no read/unread state for pull requests, so ADO Pulse keeps
/// its own: activity up to the baseline, or up to when you last opened a pull request from ADO Pulse (or
/// cleared it), counts as seen.
public struct SeenState: Sendable, Codable, Equatable {
    /// Activity before this was there before ADO Pulse first ran.
    public var baseline: Date
    /// Pull request (`PRKey.description`) → when you last looked at it.
    public var seenAt: [String: Date]

    /// On the first run, only the last few days count as new, so years of old threads don't all need you.
    public static let firstRunLookback: TimeInterval = 3 * 86_400

    public init(baseline: Date, seenAt: [String: Date] = [:]) {
        self.baseline = baseline
        self.seenAt = seenAt
    }

    public static func firstRun(now: Date = Date()) -> SeenState {
        SeenState(baseline: now.addingTimeInterval(-firstRunLookback))
    }

    public func cutoff(for key: PRKey) -> Date {
        max(baseline, seenAt[key.description] ?? .distantPast)
    }

    public mutating func markSeen<S: Sequence>(_ keys: S, at date: Date) where S.Element == PRKey {
        for key in keys {
            seenAt[key.description] = max(date, seenAt[key.description] ?? .distantPast)
        }
    }

    /// Forgets pull requests that are no longer listed and were last seen long ago.
    public mutating func prune(keeping keys: Set<PRKey>, olderThan date: Date) {
        let kept = Set(keys.map(\.description))
        seenAt = seenAt.filter { kept.contains($0.key) || $0.value > date }
    }
}

/// Decides which pull requests' details (two requests each) to fetch on a refresh. The list endpoint has
/// no "last updated" field, and comments don't change anything in it, so details are swept on a
/// schedule, besides being fetched whenever the list shows a change.
public enum RefreshPlanner {
    public struct Options: Sendable, Equatable {
        /// For pull requests with a build or check in progress.
        public var busyInterval: TimeInterval
        public var activeInterval: TimeInterval
        /// For drafts and pull requests without recent activity.
        public var quietInterval: TimeInterval
        /// At most this many pull requests per refresh, after the first.
        public var budget: Int

        public init(busyInterval: TimeInterval = 60, activeInterval: TimeInterval = 180, quietInterval: TimeInterval = 900, budget: Int = 8) {
            self.busyInterval = busyInterval
            self.activeInterval = activeInterval
            self.quietInterval = quietInterval
            self.budget = budget
        }
    }

    public struct Entry: Sendable, Equatable {
        public var fetchedAt: Date
        public var fingerprint: String
        public var isBusy: Bool
        public var isQuiet: Bool

        public init(fetchedAt: Date, fingerprint: String, isBusy: Bool = false, isQuiet: Bool = false) {
            self.fetchedAt = fetchedAt
            self.fingerprint = fingerprint
            self.isBusy = isBusy
            self.isQuiet = isQuiet
        }
    }

    public struct Candidate: Sendable, Equatable {
        public var key: PRKey
        public var fingerprint: String

        public init(key: PRKey, fingerprint: String) {
            self.key = key
            self.fingerprint = fingerprint
        }
    }

    /// New and changed pull requests first, then the ones whose details are oldest past their interval.
    /// Without a budget (the first load) every pull request without details is included.
    public static func plan(_ candidates: [Candidate], cache: [PRKey: Entry], now: Date, options: Options, limit: Int?) -> [PRKey] {
        var ranked: [(priority: Int, fetchedAt: Date, key: PRKey)] = []
        for candidate in candidates {
            guard let entry = cache[candidate.key] else {
                ranked.append((0, .distantPast, candidate.key))
                continue
            }
            if entry.fingerprint != candidate.fingerprint {
                ranked.append((1, entry.fetchedAt, candidate.key))
                continue
            }
            let age = now.timeIntervalSince(entry.fetchedAt)
            if entry.isBusy, age >= options.busyInterval {
                ranked.append((2, entry.fetchedAt, candidate.key))
            } else if entry.isQuiet ? age >= options.quietInterval : age >= options.activeInterval {
                ranked.append((3, entry.fetchedAt, candidate.key))
            }
        }
        ranked.sort { ($0.priority, $0.fetchedAt, $0.key) < ($1.priority, $1.fetchedAt, $1.key) }
        let keys = ranked.map(\.key)
        guard let limit else { return keys }
        return Array(keys.prefix(limit))
    }
}
