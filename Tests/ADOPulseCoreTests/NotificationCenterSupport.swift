import Foundation
import SQLite3
import Testing
@testable import ADOPulseCore

// MARK: - Made-up chats

/// Made-up Teams conversations. Never put real names, messages or IDs in tests.
enum Chats {
    static let dana = "19:11111111-aaaa-4aaa-8aaa-111111111111_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces"
    static let launchCrew = "19:0123456789abcdef0123456789abcdef@thread.v2"
    static let channel = "19:abcdefabcdefabcdefabcdefabcdef12@thread.tacv2"
    static let userContext = "33333333-cccc-4ccc-8ccc-333333333333"
    static let teams = "com.microsoft.teams2"
    static let slack = "com.tinyspeck.slackmacgap"
    static let outlook = "com.microsoft.Outlook"

    static let link = "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/7"
}

/// Teams message IDs are milliseconds since 1970.
func teamsMessageID(_ date: Date) -> String {
    String(Int64(date.timeIntervalSince1970 * 1_000))
}

// MARK: - Notification records

/// Builds `record.data` the way Notification Center stores notifications: a binary plist whose `req.usda`
/// is an NSKeyedArchiver archive of the user info.
enum NotificationRecord {
    static func data(
        app: String, title: String, subtitle: String = "", body: String, identifier: String = UUID().uuidString,
        userInfo: [String: Any]? = nil, date: Date
    ) -> Data {
        var request: [String: Any] = ["titl": title, "body": body, "iden": identifier, "dest": 7]
        if !subtitle.isEmpty { request["subt"] = subtitle }
        if let userInfo {
            request["usda"] = try! NSKeyedArchiver.archivedData(withRootObject: userInfo as NSDictionary, requiringSecureCoding: true)
        }
        let record: [String: Any] = [
            "app": app, "date": date.timeIntervalSinceReferenceDate, "req": request, "srce": app, "styl": 1,
            "uuid": withUnsafeBytes(of: UUID().uuid) { Data($0) },
        ]
        return try! PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
    }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// A Teams chat message's user info: the conversation, the message ID and, unless `reply` is false (as for
    /// reactions), the reply box.
    static func teamsInfo(_ conversation: String, messageID: String?, reply: Bool = true) -> [String: Any] {
        var options: [String: Any] = ["actionType": "view", "userContextId": Chats.userContext]
        if let messageID { options["messageId"] = Int64(messageID)! }
        var info: [String: Any] = [
            "default_action": "view", "default_id": conversation, "default_options": json(options),
            "default_type": "chats", "source": "tmpcore_work",
        ]
        if reply {
            info["textInputsend_action"] = "send"
            info["textInputsend_type"] = "chats"
            info["textInputsend_options"] = json(["actionType": "quickReply", "convId": conversation, "userContextId": Chats.userContext])
        }
        return info
    }

    static func teamsMessage(_ conversation: String, title: String, body: String, at date: Date, reply: Bool = true) -> Data {
        data(app: Chats.teams, title: title, body: body, userInfo: teamsInfo(conversation, messageID: teamsMessageID(date), reply: reply),
             date: date)
    }

    static func teamsChannelPost(title: String, body: String, at date: Date) -> Data {
        let id = teamsMessageID(date)
        let info: [String: Any] = [
            "default_action": "view", "default_type": "channels",
            "default_id": json(["channelId": Chats.channel, "replyChainId": Int64(id)!]),
            "default_options": json(["actionType": "view", "messageId": Int64(id)!, "userContextId": Chats.userContext]),
        ]
        return data(app: Chats.teams, title: title, body: body, userInfo: info, date: date)
    }

    /// A decoded notification, without going through a database.
    static func raw(_ data: Data, app: String, delivered: Date?) -> RawNotification? {
        RecordDecoder.decode(StoredRecord(data: data, deliveredDate: delivered, bundleIdentifier: app))
    }
}

// MARK: - A stand-in for Notification Center's database

/// Has the layout of Notification Center's `db2/db`, and writes through its own connection, as Notification
/// Center does while ADO Pulse reads.
final class TestNotificationDatabase {
    private var handle: OpaquePointer?
    private var appIDs: [String: Int64] = [:]

    static let schema = """
        CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR, badge INTEGER NULL);
        CREATE TABLE dbinfo (key VARCHAR, value VARCHAR);
        CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB,
                             request_date REAL, request_last_date REAL, delivered_date REAL,
                             presented BOOL, style INTEGER, snooze_fire_date REAL);
        """

    init(at url: URL, schema: String = TestNotificationDatabase.schema) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw TestError("Could not create \(url.path)") }
        try exec("PRAGMA journal_mode=WAL;")
        try exec(schema)
    }

    deinit {
        close()
    }

    func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    func exec(_ statements: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, statements, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw TestError(message.map { String(cString: $0) } ?? "SQLite error")
        }
    }

    private func appID(_ identifier: String) throws -> Int64 {
        if let id = appIDs[identifier] { return id }
        try exec("INSERT INTO app (identifier) VALUES ('\(identifier)');")
        let id = sqlite3_last_insert_rowid(handle)
        appIDs[identifier] = id
        return id
    }

    func add(_ data: Data, app: String, delivered: Date) throws {
        let appID = try appID(app)
        var statement: OpaquePointer?
        let sql = "INSERT INTO record (app_id, uuid, data, request_date, delivered_date, presented, style) VALUES (?, ?, ?, ?, ?, 0, 1)"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TestError(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(statement, 1, appID)
        let uuid = withUnsafeBytes(of: UUID().uuid) { Data($0) }
        _ = uuid.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
        sqlite3_bind_double(statement, 4, delivered.timeIntervalSinceReferenceDate)
        sqlite3_bind_double(statement, 5, delivered.timeIntervalSinceReferenceDate)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TestError(String(cString: sqlite3_errmsg(handle))) }
    }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ADOPulseTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}
