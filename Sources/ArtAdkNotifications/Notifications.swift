// Sources/ArtAdkNotifications/Notifications.swift
//
// Opt-in notifications adapter for ArtAdk.
//
//   import ArtAdk
//   import ArtAdkNotifications
//
//   let inbox = adk.use(notifications())
//   let stop = try await inbox.onNew { n in render(n) }        // live (websocket)
//   let page = try await inbox.list()                          // history (REST)
//   try await inbox.markRead([id])
//   try await inbox.send(SendNotificationInput(recipients: ["bob"], type: "mention", title: t, body: b))
//
// The adapter has no connection of its own: it rides the host Adk's
// websocket, REST client and auth.

import Foundation
import ArtAdk

private let notificationsChannel = "art_notifications"
private let newNotificationEvent = "notification.new"

// MARK: - Models

/// Read state of a notification.
public enum NotificationStatus: String, Sendable {
    case unread, read, archived
}

/// How a notification is delivered.
public enum NotificationChannel: String, Sendable {
    case inApp = "in_app"
    case email
}

/// A notification delivered live or listed from history.
public struct ArtNotification {
    public let id: String
    public let type: String
    public let title: String
    public let body: String
    public let data: [String: Any]?
    /// `unread`, `read` or `archived` (raw server value).
    public let status: String
    public let createdAt: String

    public init(
        id: String,
        type: String,
        title: String,
        body: String,
        data: [String: Any]? = nil,
        status: String = NotificationStatus.unread.rawValue,
        createdAt: String = ""
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.body = body
        self.data = data
        self.status = status
        self.createdAt = createdAt
    }

    init(from c: [String: Any]) {
        self.init(
            id: stringValue(c["id"]) ?? "",
            type: stringValue(c["type"]) ?? "",
            title: stringValue(c["title"]) ?? "",
            body: stringValue(c["body"]) ?? "",
            data: c["data"] as? [String: Any],
            status: stringValue(c["status"]) ?? NotificationStatus.unread.rawValue,
            createdAt: stringValue(c["created_at"]) ?? stringValue(c["createdAt"]) ?? ""
        )
    }
}

/// Adapter options.
public struct NotificationsOptions {
    /// Gateway origin for the REST API. Defaults to the ADK gateway origin
    /// (where `/api/<tenant>/...` lives).
    public var apiBaseUrl: String?

    public init(apiBaseUrl: String? = nil) {
        self.apiBaseUrl = apiBaseUrl
    }
}

/// Filters for `list(_:)`.
public struct NotificationListParams {
    public var status: NotificationStatus?
    public var page: Int?
    public var limit: Int?

    public init(status: NotificationStatus? = nil, page: Int? = nil, limit: Int? = nil) {
        self.status = status
        self.page = page
        self.limit = limit
    }
}

/// One page of notifications.
public struct NotificationPage {
    public let notifications: [ArtNotification]
    public let total: Int
}

/// Input for `send(_:)`.
public struct SendNotificationInput {
    public var recipients: [String]
    public var type: String
    public var title: String
    public var body: String
    public var data: [String: Any]?
    /// Delivery channels (sent as `notify_channels`); `nil` = in-app only.
    public var channels: [NotificationChannel]?
    public var dedupKey: String?

    public init(
        recipients: [String],
        type: String,
        title: String,
        body: String,
        data: [String: Any]? = nil,
        channels: [NotificationChannel]? = nil,
        dedupKey: String? = nil
    ) {
        self.recipients = recipients
        self.type = type
        self.title = title
        self.body = body
        self.data = data
        self.channels = channels
        self.dedupKey = dedupKey
    }
}

/// Result of `send(_:)`.
public struct SendNotificationResult {
    public let created: Int
    public let skipped: Int
}

// MARK: - API

/// Notifications API installed by `adk.use(notifications())`.
public final class NotificationsApi {

    private let context: AdkPluginContext
    private let options: NotificationsOptions
    private let lock = NSLock()
    private var subscription: Subscription?

    init(context: AdkPluginContext, options: NotificationsOptions) {
        self.context = context
        self.options = options
    }

    // MARK: Live (websocket)

    /// Subscribes to live notifications (`notification.new` on the
    /// `art_notifications` channel). Returns a closure that unsubscribes.
    public func onNew(_ callback: @escaping (ArtNotification) -> Void) async throws -> () -> Void {
        let sub = try await liveSubscription()
        let token = sub.bind(event: newNotificationEvent) { payload in
            if let notification = normalize(payload) { callback(notification) }
        }
        return { [weak sub] in
            sub?.remove(event: newNotificationEvent, id: token)
        }
    }

    private func liveSubscription() async throws -> Subscription {
        if let cached = cachedSubscription() { return cached }
        let raw = try await context.subscribe(notificationsChannel)
        guard let sub = raw as? Subscription else {
            throw ARTError.serverError("Channel \(notificationsChannel) did not yield a Subscription")
        }
        cache(sub)
        return sub
    }

    private func cachedSubscription() -> Subscription? {
        lock.lock(); defer { lock.unlock() }
        return subscription
    }

    private func cache(_ sub: Subscription) {
        lock.lock(); defer { lock.unlock() }
        subscription = sub
    }

    // MARK: CRUD (REST, via the gateway)

    /// Lists notifications (history).
    public func list(_ params: NotificationListParams = NotificationListParams()) async throws -> NotificationPage {
        var query: [String: String] = [:]
        if let status = params.status { query["status"] = status.rawValue }
        if let page = params.page { query["page"] = String(page) }
        if let limit = params.limit { query["limit"] = String(limit) }

        let data = try await call(path(), method: "GET", query: query)
        let items = (data["notifications"] as? [[String: Any]] ?? []).map(ArtNotification.init(from:))
        return NotificationPage(notifications: items, total: intValue(data["total"]) ?? 0)
    }

    /// Number of unread notifications.
    public func unreadCount() async throws -> Int {
        let data = try await call(path("/unread-count"), method: "GET")
        return intValue(data["unread_count"]) ?? 0
    }

    /// Marks the given notifications read, or all unread when `ids` is
    /// `nil` or empty. Returns the number modified.
    @discardableResult
    public func markRead(_ ids: [String]? = nil) async throws -> Int {
        let list = ids ?? []
        let data = try await call(
            path("/mark-read"), method: "POST",
            payload: ["ids": list, "all": list.isEmpty]
        )
        return intValue(data["modified"]) ?? 0
    }

    /// Sends a notification to one or more recipients (authorized
    /// server-side).
    @discardableResult
    public func send(_ input: SendNotificationInput) async throws -> SendNotificationResult {
        var payload: [String: Any] = [
            "tenant": try tenant(),
            "type": input.type,
            "recipients": input.recipients,
            "title": input.title,
            "body": input.body,
        ]
        if let data = input.data { payload["data"] = data }
        // The trigger event binds `notify_channels`; a `channels` key is
        // ignored by the service (in-app only).
        if let channels = input.channels { payload["notify_channels"] = channels.map(\.rawValue) }
        if let dedupKey = input.dedupKey { payload["dedup_key"] = dedupKey }

        let data = try await call(path("/notify"), method: "POST", payload: payload)
        return SendNotificationResult(
            created: intValue(data["created"]) ?? 0,
            skipped: intValue(data["skipped"]) ?? 0
        )
    }

    // MARK: Internals

    private func tenant() throws -> String {
        try context.getCredentials().orgTitle
    }

    private func base() -> String {
        options.apiBaseUrl ?? context.baseUrl()
    }

    private func path(_ suffix: String = "") throws -> String {
        "/api/\(encodePathComponent(try tenant()))/notifications\(suffix)"
    }

    /// REST call through the host ADK; returns the response's `data` object,
    /// or the whole response when it has no `data` wrapper.
    private func call(
        _ endpoint: String,
        method: String,
        query: [String: String]? = nil,
        payload: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let response = try await context.call(endpoint, CallApiProps(
            method: method,
            payload: payload,
            queryParams: (query?.isEmpty ?? true) ? nil : query,
            baseUrl: base()
        ))
        let root = response as? [String: Any] ?? [:]
        return root["data"] as? [String: Any] ?? root
    }
}

// MARK: - Plugin

/// Registers the adapter with `adk.use(_:)`.
public struct NotificationsPlugin: AdkPlugin {
    public let name = "notifications"
    public let options: NotificationsOptions

    public init(options: NotificationsOptions = NotificationsOptions()) {
        self.options = options
    }

    public func install(_ context: AdkPluginContext) -> NotificationsApi {
        NotificationsApi(context: context, options: options)
    }
}

/// Plugin factory — `let inbox = adk.use(notifications())`.
public func notifications(_ options: NotificationsOptions = NotificationsOptions()) -> NotificationsPlugin {
    NotificationsPlugin(options: options)
}

// MARK: - Helpers

/// `bind()` delivers the parsed `content`; also accept a wrapped
/// `{ content }` / `{ data }` shape.
func normalize(_ payload: Any) -> ArtNotification? {
    guard let dict = payload as? [String: Any] else { return nil }
    let content: [String: Any]?
    if stringValue(dict["id"]) != nil || stringValue(dict["title"]) != nil {
        content = dict
    } else {
        content = (dict["content"] as? [String: Any]) ?? (dict["data"] as? [String: Any])
    }
    guard let content, stringValue(content["id"]) != nil else { return nil }
    return ArtNotification(from: content)
}

private func stringValue(_ value: Any?) -> String? {
    switch value {
    case let string as String: return string.isEmpty ? nil : string
    case let number as NSNumber: return number.stringValue
    default: return nil
    }
}

private func intValue(_ value: Any?) -> Int? {
    switch value {
    case let int as Int: return int
    case let number as NSNumber: return number.intValue
    case let string as String: return Int(string)
    default: return nil
    }
}

private let pathComponentAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
)

private func encodePathComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: pathComponentAllowed) ?? value
}
