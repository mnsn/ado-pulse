import Foundation

/// A link to an Azure DevOps pull request, found in a message.
public struct PullRequestLink: Sendable, Equatable, Hashable, Codable {
    public var organization: String
    public var project: String
    public var repository: String
    public var number: Int

    public init(organization: String, project: String, repository: String, number: Int) {
        self.organization = organization
        self.project = project
        self.repository = repository
        self.number = number
    }

    public var key: PRKey { PRKey(organization, number) }

    public var url: URL {
        ADOEndpoint.pullRequestPage(organization: organization, project: project, repository: repository, id: number)
    }

    /// `dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}` and the older
    /// `{org}.visualstudio.com[/DefaultCollection]/{project}/_git/{repo}/pullrequest/{id}`, with or without
    /// the scheme, a query or a fragment.
    nonisolated(unsafe) private static let pattern = try! Regex(
        #"(?i)(?:https?://)?(?:dev\.azure\.com/([A-Za-z0-9][A-Za-z0-9-]*)|([A-Za-z0-9][A-Za-z0-9-]*)\.visualstudio\.com(?:/DefaultCollection)?)/([^\s/?#<>"'\]\[()]+)/_git/([^\s/?#<>"'\]\[()]+)/pullrequest/([0-9]{1,9})(?![0-9])"#
    )

    /// Every pull request linked in `text`, once each, in order.
    public static func find(in text: String) -> [PullRequestLink] {
        guard text.localizedCaseInsensitiveContains("pullrequest") else { return [] }
        var links: [PullRequestLink] = []
        for match in text.matches(of: pattern) {
            let organization = (match.output[1].substring ?? match.output[2].substring).map(String.init) ?? ""
            guard !organization.isEmpty,
                  let project = match.output[3].substring.map({ String($0).removingPercentEncoding ?? String($0) }),
                  let repository = match.output[4].substring.map({ String($0).removingPercentEncoding ?? String($0) }),
                  let number = match.output[5].substring.flatMap({ Int($0) }), number > 0
            else { continue }
            let link = PullRequestLink(organization: organization, project: project, repository: repository, number: number)
            if !links.contains(where: { $0.key == link.key }) {
                links.append(link)
            }
        }
        return links
    }
}

/// Someone sent you a link to a pull request, in Teams, Slack, an email or any other app that posts
/// notifications. Only this is kept: never the message itself.
public struct ChatLink: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var link: PullRequestLink
    /// The bundle identifier of the app that posted the notification.
    public var app: String
    public var sender: String?
    public var sentAt: Date
    /// The app's identity for the notification (Notification Center's, when it gives none), so it's counted
    /// once. An app can post a new message under the same one, replacing the notification.
    public var notificationKey: String
    /// Teams: the chat and the message, to open the message in Teams.
    public var conversation: String?
    public var messageID: String?

    public init(
        link: PullRequestLink, app: String, sender: String?, sentAt: Date, notificationKey: String,
        conversation: String? = nil, messageID: String? = nil
    ) {
        self.link = link
        self.app = app
        self.sender = sender
        self.sentAt = sentAt
        self.notificationKey = notificationKey
        self.conversation = conversation
        self.messageID = messageID
    }

    /// The app, its notification, and the pull request: another app may use the same notification identifier.
    public var id: String { "\(app)|\(notificationKey)#\(link.key)" }
    public var key: PRKey { link.key }
    public var appName: String { ChatApps.name(for: app) }

    /// Opens the message in Teams; nil for other apps, which are only brought forward.
    public var messageURL: URL? {
        guard ChatApps.isTeams(app), let conversation else { return nil }
        if let messageID, let url = TeamsLink.message(conversation: conversation, messageID: messageID) { return url }
        return TeamsLink.chat(conversation: conversation)
    }
}

/// Names for the apps people send links in.
public enum ChatApps {
    public static let teams = ["com.microsoft.teams2", "com.microsoft.teams"]

    private static let names: [String: String] = [
        "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
        "com.tinyspeck.slackmacgap": "Slack", "com.microsoft.Outlook": "Outlook", "com.apple.mail": "Mail",
        "com.apple.MobileSMS": "Messages", "net.whatsapp.WhatsApp": "WhatsApp", "desktop.WhatsApp": "WhatsApp",
        "ru.keepcoder.Telegram": "Telegram", "com.hnc.Discord": "Discord", "us.zoom.xos": "Zoom",
        "com.readdle.smartemail-Mac": "Spark", "com.superhuman.electron": "Superhuman",
    ]

    public static func isTeams(_ bundleIdentifier: String) -> Bool {
        teams.contains(bundleIdentifier)
    }

    /// "Teams", or the last part of an app's identifier, capitalized.
    public static func name(for bundleIdentifier: String) -> String {
        if let name = names[bundleIdentifier] { return name }
        let last = bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}

/// Finds pull request links in stored notifications.
public enum ChatLinkScanner {
    /// ADO Pulse's own notifications mention pull requests too.
    public static let ownBundleIdentifier = "com.asaf.ADOPulse"

    /// Each pull request linked in the notification, with who sent it. Teams notifications count only
    /// when they're chat messages: not reactions, channel posts or calls. Azure DevOps' own emails don't
    /// count, since ADO Pulse already shows what they announce.
    public static func links(in notification: RawNotification) -> [ChatLink] {
        guard notification.bundleIdentifier != ownBundleIdentifier, let sentAt = notification.deliveredAt else { return [] }
        let text = [notification.title, notification.subtitle, notification.body].joined(separator: "\n")
        let found = PullRequestLink.find(in: text)
        guard !found.isEmpty else { return [] }

        var sender: String?
        var conversation: String?
        var messageID: String?
        if ChatApps.isTeams(notification.bundleIdentifier) {
            guard let message = TeamsMessage(notification) else { return [] }
            sender = message.sender
            conversation = message.conversation
            messageID = message.messageID
        } else {
            let title = notification.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if isFromAzureDevOps(title) { return [] }
            sender = title.isEmpty ? nil : String(title.prefix(80))
        }
        return found.map {
            ChatLink(link: $0, app: notification.bundleIdentifier, sender: sender, sentAt: sentAt,
                     notificationKey: notification.key, conversation: conversation, messageID: messageID)
        }
    }

    /// Mail and Outlook show the sender as the title: Azure DevOps' notification emails come from it.
    static func isFromAzureDevOps(_ sender: String) -> Bool {
        ["azure devops", "visual studio team services", "azuredevops@"].contains { sender.lowercased().contains($0) }
    }

    /// Reads every stored notification and returns the links in them.
    public static func scan(_ records: [StoredRecord]) -> [ChatLink] {
        records.compactMap(RecordDecoder.decode).flatMap(links(in:))
    }
}

/// A Teams chat message, from its notification's user info (as of Teams 26261): `default_type` `chats`,
/// `default_id` the chat, `default_options` JSON with `messageId`, and a reply box (`textInputsend_*`)
/// that reactions and other chat notifications don't have. Channel posts have `default_type` `channels`.
struct TeamsMessage {
    var conversation: String
    var messageID: String?
    var sender: String?

    init?(_ notification: RawNotification) {
        let info = notification.userInfo
        guard info["default_type"]?.trimmingCharacters(in: .whitespaces) == "chats",
              info["textInputsend_type"] != nil || info["textInputsend_options"] != nil
        else { return nil }
        let reply = Self.json(info["textInputsend_options"])
        let candidates = [info["default_id"], reply?["convId"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let conversation = candidates.first(where: TeamsLink.isValidConversation) else { return nil }
        self.conversation = conversation
        messageID = Self.messageID(Self.json(info["default_options"])?["messageId"])

        if conversation.lowercased().hasSuffix("@unq.gbl.spaces") {
            // A 1:1 chat's title is the sender.
            let title = notification.title.trimmingCharacters(in: .whitespacesAndNewlines)
            sender = title.isEmpty ? nil : String(title.prefix(80))
        } else {
            // Group chat bodies read "Sender: text".
            let body = notification.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let separator = body.range(of: ": ") {
                let name = body[..<separator.lowerBound]
                if !name.isEmpty, name.count <= 80, !name.contains(where: \.isNewline) {
                    sender = String(name)
                }
            }
        }
    }

    static func messageID(_ value: Any?) -> String? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let id = number.int64Value
            return id > 0 ? String(id) : nil
        }
        if let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
           text.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return text
        }
        return nil
    }

    static func json(_ text: String?) -> [String: Any]? {
        guard let data = text?.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              data.first == UInt8(ascii: "{")
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Links that open a chat in the Teams app.
public enum TeamsLink {
    /// Teams thread IDs look like `19:<id>@<domain>`, for example `19:…@unq.gbl.spaces` or `19:…@thread.v2`.
    public static func isValidConversation(_ id: String) -> Bool {
        id.wholeMatch(of: /19:[^\s"'<>{}\[\]()|\\,;&?#\/]+@[A-Za-z0-9.\-]+/) != nil
    }

    /// Teams' documented link to a message in a chat (the form "Copy link" gives), with the app's `msteams:`
    /// scheme so no browser is involved.
    public static func message(conversation: String, messageID: String) -> URL? {
        guard isValidConversation(conversation), !messageID.isEmpty, messageID.allSatisfy({ $0.isASCII && $0.isNumber }),
              let id = encode(conversation)
        else { return nil }
        return URL(string: "msteams:/l/message/\(id)/\(messageID)?context=%7B%22contextType%22%3A%22chat%22%7D")
    }

    /// Opens a chat without a message. Undocumented, so only used when there's no message ID.
    public static func chat(conversation: String) -> URL? {
        guard isValidConversation(conversation), let id = encode(conversation) else { return nil }
        return URL(string: "msteams:/l/chat/\(id)/0")
    }

    private static func encode(_ text: String) -> String? {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        ))
    }
}

/// The pull request links ADO Pulse has found, kept after Notification Center drops the notifications
/// (it keeps only the latest hundred or so per app, about two days of Teams).
public struct ChatLinkState: Sendable, Codable, Equatable {
    public var links: [ChatLink]

    /// Links older than this are forgotten.
    public static let keepFor: TimeInterval = 14 * 86_400

    public init(links: [ChatLink] = []) {
        self.links = links
    }

    /// Adds the links not known yet, and takes the newer message when an app replaced a notification with one
    /// about the same pull request. Returns whether anything changed.
    @discardableResult
    public mutating func merge(_ found: [ChatLink]) -> Bool {
        var changed = false
        for link in found {
            if let index = links.firstIndex(where: { $0.id == link.id }) {
                let known = links[index]
                guard link.sentAt > known.sentAt || (link.sentAt == known.sentAt && link.messageID != known.messageID) else { continue }
                links[index] = link
            } else {
                links.append(link)
            }
            changed = true
        }
        if changed { links.sort { ($0.sentAt, $0.id) < ($1.sentAt, $1.id) } }
        return changed
    }

    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let kept = links.filter { now.timeIntervalSince($0.sentAt) <= Self.keepFor }
        guard kept.count != links.count else { return false }
        links = kept
        return true
    }

    /// The pull requests linked, for the engine to read the ones you're not already on.
    public var keys: Set<PRKey> { Set(links.map(\.key)) }

    public func links(for key: PRKey) -> [ChatLink] {
        links.filter { $0.key == key }
    }

    /// Uses the spelling of the organizations you watch: links may name them in any case.
    public static func canonical(_ links: [ChatLink], organizations: [String]) -> [ChatLink] {
        links.map { link in
            guard let match = organizations.first(where: { $0.caseInsensitiveCompare(link.link.organization) == .orderedSame }),
                  match != link.link.organization
            else { return link }
            var copy = link
            copy.link.organization = match
            return copy
        }
    }
}
