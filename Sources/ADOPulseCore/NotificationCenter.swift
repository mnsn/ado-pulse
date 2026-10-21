import Foundation
import SQLite3

/// Notification Center's database, where macOS keeps the notifications apps post (about the latest
/// hundred per app). ADO Pulse reads it, only when you turn on pull requests sent in chats, to find
/// links to pull requests in what people send you. It never writes to it.
public enum NotificationCenterDatabase {
    /// Points ADO Pulse at another copy of the database, such as a test fixture.
    public static let overrideVariable = "ADO_PULSE_NOTIFICATIONS_DB"

    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let path = environment[overrideVariable], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    /// Without these, nothing can be read reliably, so nothing is guessed.
    static let requiredColumns: [(table: String, column: String)] = [
        ("app", "app_id"), ("app", "identifier"), ("record", "app_id"), ("record", "data"),
    ]

    /// Every stored notification, from every app, in one short read-only transaction.
    public static func load(at url: URL) throws -> [StoredRecord] {
        do {
            return try load(from: SQLiteConnection(readOnly: url))
        } catch let error as SQLiteError where error.primaryCode == SQLITE_CANTOPEN && isClosedWALDatabase(url) {
            // A read-only connection can't recreate the write-ahead log, which SQLite removes when the
            // last writer closes the database. Without a log or journal, the file holds every committed
            // change, so read it as it is.
            do {
                return try load(from: SQLiteConnection(readOnly: url, immutable: true))
            } catch let fallback as SQLiteError {
                throw NotificationDatabaseError.sqlite(fallback)
            }
        } catch let error as SQLiteError {
            throw NotificationDatabaseError.sqlite(error)
        }
    }

    private static func isClosedWALDatabase(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.path)
            && !fileManager.fileExists(atPath: url.path + "-wal")
            && !fileManager.fileExists(atPath: url.path + "-journal")
    }

    private static func load(from connection: SQLiteConnection) throws -> [StoredRecord] {
        let layout = try readLayout(connection)
        let missing = requiredColumns.filter { layout[$0.table]?.contains($0.column) != true }.map { "\($0.table).\($0.column)" }
        guard missing.isEmpty else {
            throw NotificationDatabaseError.layoutChanged(missing: missing)
        }
        let apps = try connection.rows("SELECT app_id, identifier FROM app") { row in (row.int64(0), row.text(1)) }
        var identifiers: [Int64: String] = [:]
        for (id, identifier) in apps {
            if let id, let identifier { identifiers[id] = identifier }
        }
        // Optional columns are read only if they exist; the names come from this fixed list.
        let optional = ["rec_id", "uuid", "delivered_date", "request_date"]
            .map { layout["record"]?.contains($0) == true ? $0 : "NULL" }
        return try connection.rows("SELECT app_id, data, \(optional.joined(separator: ", ")) FROM record") { row in
            StoredRecord(
                recordID: row.int64(2),
                uuid: row.blob(3),
                data: row.blob(1),
                deliveredDate: row.double(4).map(Date.init(timeIntervalSinceReferenceDate:)),
                requestDate: row.double(5).map(Date.init(timeIntervalSinceReferenceDate:)),
                bundleIdentifier: row.int64(0).flatMap { identifiers[$0] } ?? ""
            )
        }
    }

    private static func readLayout(_ connection: SQLiteConnection) throws -> [String: [String]] {
        let tables = try connection.rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") {
            $0.text(0) ?? ""
        }
        var layout: [String: [String]] = [:]
        for table in tables where !table.isEmpty {
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            layout[table] = try connection.rows("PRAGMA table_info(\(quoted))") { $0.text(1) ?? "" }
        }
        return layout
    }
}

/// Whether ADO Pulse can read Notification Center's database.
public enum AccessStatus: String, Sendable, Equatable, Codable {
    case granted
    /// Privacy protection: ADO Pulse needs Full Disk Access.
    case denied
    /// There's no database where Notification Center keeps it.
    case missing
}

public enum DatabaseAccess {
    /// Finds out by opening the file: privacy protection only shows when you try.
    /// `FileManager.isReadableFile` checks POSIX permissions, and says yes even without access.
    public static func check(_ url: URL) -> AccessStatus {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        let error = errno
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        guard error == ENOENT || error == ENOTDIR else { return .denied }
        // Without access, macOS can hide the folder's contents too.
        let folder = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let folderError = errno
        if folder >= 0 {
            close(folder)
            return .missing
        }
        return folderError == EPERM || folderError == EACCES ? .denied : .missing
    }
}

public enum NotificationDatabaseError: Error, Sendable, Equatable, CustomStringConvertible {
    case sqlite(SQLiteError)
    /// Required tables or columns are gone: Notification Center's format changed.
    case layoutChanged(missing: [String])

    public var description: String {
        switch self {
        case .sqlite(let error):
            return "Couldn't read Notification Center's database: \(error.message)"
        case .layoutChanged(let missing):
            return "Notification Center's database has changed (\(missing.joined(separator: ", ")) is missing)."
        }
    }
}

/// One row of the `record` table.
public struct StoredRecord: Sendable, Equatable {
    public var recordID: Int64?
    public var uuid: Data?
    public var data: Data?
    public var deliveredDate: Date?
    public var requestDate: Date?
    public var bundleIdentifier: String

    public init(
        recordID: Int64? = nil, uuid: Data? = nil, data: Data?, deliveredDate: Date? = nil, requestDate: Date? = nil,
        bundleIdentifier: String
    ) {
        self.recordID = recordID
        self.uuid = uuid
        self.data = data
        self.deliveredDate = deliveredDate
        self.requestDate = requestDate
        self.bundleIdentifier = bundleIdentifier
    }
}

/// A stored notification, decoded but not yet interpreted.
public struct RawNotification: Sendable, Equatable {
    /// Stable identity: the request identifier (`req.iden`), else the record's UUID, else its row ID.
    public var key: String
    public var bundleIdentifier: String
    public var deliveredAt: Date?
    public var title: String
    public var subtitle: String
    public var body: String
    /// The user info (`req.usda`): text and number values, as text.
    public var userInfo: [String: String]
    /// Every user-info key, including those whose values aren't text or numbers.
    public var userInfoKeys: Set<String>

    public init(
        key: String, bundleIdentifier: String, deliveredAt: Date?, title: String = "", subtitle: String = "", body: String = "",
        userInfo: [String: String] = [:], userInfoKeys: Set<String>? = nil
    ) {
        self.key = key
        self.bundleIdentifier = bundleIdentifier
        self.deliveredAt = deliveredAt
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.userInfo = userInfo
        self.userInfoKeys = userInfoKeys ?? Set(userInfo.keys)
    }
}

/// Decodes `record.data`: a binary plist `{app, date, req: {titl, subt, body, iden, usda, …}, uuid, …}` whose
/// `req.usda` is the notification's user info, archived with NSKeyedArchiver.
public enum RecordDecoder {
    /// Plist classes only: anything else in an archive fails to decode instead of being instantiated.
    private static let archiveClasses: [AnyClass] = [
        NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self, NSDate.self,
    ]

    /// Nil for a record that isn't a notification ADO Pulse can read.
    public static func decode(_ record: StoredRecord) -> RawNotification? {
        guard let data = record.data, !data.isEmpty,
              let plist = propertyList(data) as? [String: Any],
              let request = plist["req"] as? [String: Any]
        else { return nil }

        let identifier = (request["iden"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let uuid = record.uuid.flatMap { $0.isEmpty ? nil : $0 } ?? (plist["uuid"] as? Data)
        let key = identifier ?? uuid.map { $0.map { String(format: "%02x", $0) }.joined() }
            ?? record.recordID.map { "rec\($0)" } ?? "record"

        var info: [String: String] = [:]
        var keys = Set<String>()
        if let value = request["usda"], let dictionary = userInfo(value) {
            for (name, item) in dictionary {
                keys.insert(name)
                if let text = scalarText(item) { info[name] = text }
            }
        }
        let bundleIdentifier = record.bundleIdentifier.isEmpty ? (plist["app"] as? String ?? "") : record.bundleIdentifier
        return RawNotification(
            key: key,
            bundleIdentifier: bundleIdentifier,
            deliveredAt: record.deliveredDate ?? date(plist["date"]) ?? record.requestDate,
            title: request["titl"] as? String ?? "",
            subtitle: request["subt"] as? String ?? "",
            body: request["body"] as? String ?? "",
            userInfo: info,
            userInfoKeys: keys
        )
    }

    /// A plist, unpacking it when it's an NSKeyedArchiver archive.
    static func propertyList(_ data: Data) -> Any? {
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        if let dictionary = value as? [String: Any], dictionary["$archiver"] as? String == "NSKeyedArchiver" {
            return try? NSKeyedUnarchiver.unarchivedObject(ofClasses: archiveClasses, from: data)
        }
        return value
    }

    /// The user info dictionary, from archived bytes or an inline dictionary, unwrapping a `root` entry.
    private static func userInfo(_ value: Any) -> [String: Any]? {
        var decoded: Any? = value
        if let data = value as? Data {
            decoded = propertyList(data)
        }
        guard var dictionary = decoded as? [String: Any] else { return nil }
        if dictionary.count == 1, let root = dictionary["root"] as? [String: Any] {
            dictionary = root
        }
        return dictionary
    }

    private static func scalarText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let seconds = value as? Double { return Date(timeIntervalSinceReferenceDate: seconds) }
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        return nil
    }
}
