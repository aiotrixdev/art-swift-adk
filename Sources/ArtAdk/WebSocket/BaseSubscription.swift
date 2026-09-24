// Sources/ARTSdk/WebSocket/BaseSubscription.swift
//
// Channel subscription base.

import Foundation

// MARK: - PendingAck
private struct PendingAck {
    let continuation: CheckedContinuation<String, Error>
    let timer: Task<Void, Never>
}

// MARK: - Inbound queue element
private struct InboundMessage: @unchecked Sendable {
    let event: String
    let payload: [String: Any]
}

// MARK: - EventBuffer
/// Insertion-ordered per-event buffer: replay walks events in
/// first-arrival order, then messages in arrival order.
struct EventBuffer {
    private(set) var order: [String] = []
    private(set) var items: [String: [[String: Any]]] = [:]

    init() {}

    init(_ dictionary: [String: [[String: Any]]]) {
        for key in dictionary.keys.sorted() {
            order.append(key)
            items[key] = dictionary[key]
        }
    }

    var isEmpty: Bool { order.isEmpty }
    var dictionary: [String: [[String: Any]]] { items }

    mutating func append(_ event: String, _ entry: [String: Any]) {
        if items[event] == nil { order.append(event) }
        items[event, default: []].append(entry)
    }

    /// Removes and returns the entries buffered for `event`.
    mutating func take(_ event: String) -> [[String: Any]] {
        guard let entries = items.removeValue(forKey: event) else { return [] }
        order.removeAll { $0 == event }
        return entries
    }

    /// Removes and returns every entry in replay order.
    mutating func drainAll() -> [(event: String, entry: [String: Any])] {
        let drained = order.flatMap { event in
            (items[event] ?? []).map { (event: event, entry: $0) }
        }
        order.removeAll()
        items.removeAll()
        return drained
    }
}

// MARK: - BaseSubscription
open class BaseSubscription {

    /// Channels handled locally, without a `channel-subscribe` round trip.
    static let reservedChannels: Set<String> = ["art_config", "art_secure"]
    /// Channels that never take part in ACKs / ref tracking.
    static let controlChannels: Set<String> = ["art_config", "art_secure", "art_presence"]

    public let connectionID: String
    public let websocketHandler: IWebsocketHandler
    public let emitter = EventEmitter()

    /// Guards the mutable state below (shared with `Subscription`).
    let stateLock = ArtLock()
    private var _isSubscribed = false
    private var _isListening = false
    private var _channelConfig: ChannelConfig
    private var _presenceUsers: [String]
    /// Non-thread events buffered until a listener attaches.
    var bufferStorage = EventBuffer()

    private var pendingAcks: [String: PendingAck] = [:]
    /// How long `push` waits for the server `SA` ACK on targeted channels,
    /// in milliseconds.
    var ackTimeoutMs: Double = 50_000
    private var messageCount: Int = 0

    // In-order inbound delivery (see `enqueue`).
    private let inboundStream: AsyncStream<InboundMessage>
    private let inboundContinuation: AsyncStream<InboundMessage>.Continuation
    private var inboundTask: Task<Void, Never>?

    public var isSubscribed: Bool {
        get { stateLock.sync { _isSubscribed } }
        set { stateLock.sync { _isSubscribed = newValue } }
    }

    public var isListening: Bool {
        get { stateLock.sync { _isListening } }
        set { stateLock.sync { _isListening = newValue } }
    }

    public var channelConfig: ChannelConfig {
        get { stateLock.sync { _channelConfig } }
        set { stateLock.sync { _channelConfig = newValue } }
    }

    public var presenceUsers: [String] {
        get { stateLock.sync { _presenceUsers } }
        set { stateLock.sync { _presenceUsers = newValue } }
    }

    /// Snapshot of buffered non-thread events, keyed by event name.
    public var messageBuffer: [String: [[String: Any]]] {
        get { stateLock.sync { bufferStorage.dictionary } }
        set { stateLock.sync { bufferStorage = EventBuffer(newValue) } }
    }

    public init(
        connectionID: String,
        channelConfig: ChannelConfig,
        websocketHandler: IWebsocketHandler,
        process: String = "subscribe"
    ) {
        self.connectionID = connectionID
        self.websocketHandler = websocketHandler
        self._channelConfig = channelConfig
        self._presenceUsers = channelConfig.presenceUsers

        var continuation: AsyncStream<InboundMessage>.Continuation!
        self.inboundStream = AsyncStream { continuation = $0 }
        self.inboundContinuation = continuation

        if process == "subscribe" { _isSubscribed = true }
        else if process == "presence" { _isListening = true }

        // Single consumer: frames for this subscription are handled one at a
        // time in arrival order. `handleMessage` dispatches to the subclass
        // override.
        let stream = inboundStream
        inboundTask = Task { [weak self] in
            for await message in stream {
                guard let self else { return }
                await self.handleMessage(event: message.event, payload: message.payload)
            }
        }
    }

    deinit {
        inboundContinuation.finish()
        inboundTask?.cancel()
    }

    // MARK: - Inbound queue
    /// Queues an inbound frame for in-order delivery to `handleMessage`.
    /// Lock-free, so the socket may call it while holding its own lock.
    func enqueue(event: String, payload: [String: Any]) {
        inboundContinuation.yield(InboundMessage(event: event, payload: payload))
    }

    // MARK: - Validate subscription
    public func validateSubscription(process: String) async {

        let config = channelConfig
        guard !["art_config", "art_secure"].contains(config.channelName) else { return }

        var channelName = config.channelName

        if !config.channelNamespace.isEmpty {
            channelName += ":\(config.channelNamespace)"
        }

        do {
            let fresh = try await subscribe_to_channel(
                channel: channelName,
                process: process,
                websocketHandler: websocketHandler
            )
            channelConfig = fresh
            if process == "presence" {
                isListening = true
            }
        } catch {
            ArtLog.error("validateSubscription(\(process)) failed for \(channelName): \(error)")
        }
    }

    // MARK: - Presence
    public func fetchPresence(
        unique: Bool = true,
        callback: @escaping ([String]) -> Void
    ) async throws -> (() async throws -> Void) {

        let previousPresenceData = presenceUsers

        if !previousPresenceData.isEmpty {
            callback(previousPresenceData)
        }

        await validateSubscription(process: "presence")

        if !isListening {
            throw ARTError.serverError("Not subscribed for presence")
        }

        emitter.on("art_presence") { [weak self] payload in

            // Any truthy `error` suppresses the update.
            guard let self,
                  let data = payload as? [String: Any],
                  !ArtJSON.isTruthy(data["error"]),
                  let usernames = data["usernames"] as? [String] else { return }

            self.presenceUsers = usernames

            var response: [String] = []

            if unique {
                var seen = Set<String>()

                for user in usernames {
                    let parts = user.split(separator: ":")
                    let name = String(parts.first ?? "")

                    if !seen.contains(name) {
                        seen.insert(name)
                        response.append(name)
                    }
                }
            } else {
                response = usernames
            }

            callback(response)
        }

        try await push(
            event: "art_presence",
            data: [:]
        )

        return {
            let config = self.channelConfig
            _ = try await unsubscribe_from_channel(
                channel: config.channelName,
                subscriptionID: config.subscriptionID ?? "",
                process: "presence",
                websocketHandler: self.websocketHandler
            )
        }
    }


    // MARK: - ACK
    /// Sends a delivery acknowledgement (`MA` / `CA`) for targeted and
    /// secure channels.
    public func acknowledge(_ request: [String: Any], _ returnFlag: String) {

        let config = channelConfig
        guard config.channelType == "targeted" ||
              config.channelType == "secure" else { return }

        guard let channel = request["channel"] as? String,
              !BaseSubscription.controlChannels.contains(channel) else { return }

        var response: [String: Any] = [
            "channel": channel,
            "return_flag": returnFlag
        ]

        let keys = [
            "namespace",
            "id",
            "ref_id",
            "from",
            "to_username",
            "to",
            "pipeline_id",
            "interceptor_name",
            "attempt_id"
        ]

        for key in keys {
            if let v = request[key] {
                response[key] = v
            }
        }

        if let str = try? ArtJSON.stringify(response) {
            _ = websocketHandler.sendMessage(str)
        }
    }

    // MARK: - Handle ACK
    /// Resolves the pending `push` whose `ref_id` matches a server `SA`.
    public func handleMessageAcks(
        event: String,
        returnFlag: String,
        data: [String: Any]
    ) {

        guard returnFlag == "SA",
              let refId = data["ref_id"] as? String else { return }

        let entry = stateLock.sync { pendingAcks.removeValue(forKey: refId) }
        guard let entry else { return }
        entry.timer.cancel()
        entry.continuation.resume(returning: refId)
    }

    private func failPendingAck(_ refId: String, _ error: Error) {
        let entry = stateLock.sync { pendingAcks.removeValue(forKey: refId) }
        entry?.continuation.resume(throwing: error)
    }

    // MARK: - Subscribe
    public func subscribe() async {

        guard !BaseSubscription.reservedChannels.contains(channelConfig.channelName) else {
            return
        }

        isSubscribed = true

        do {

            let config = try await subscribe_to_channel(
                channel: channelConfig.channelName,
                process: "subscribe",
                websocketHandler: websocketHandler
            )

            channelConfig = config

        } catch {
            ArtLog.error("subscribe failed for \(channelConfig.channelName): \(error)")
            isSubscribed = false
        }
    }

    // MARK: - Unsubscribe
    public func unsubscribe() async {

        let config = channelConfig
        guard let subID = config.subscriptionID, !subID.isEmpty else { return }

        do {

            let ok = try await unsubscribe_from_channel(
                channel: config.channelName,
                subscriptionID: subID,
                process: "subscribe",
                websocketHandler: websocketHandler
            )

            if ok {
                websocketHandler.removeSubscription(channel: config.channelName)
            } else {
                ArtLog.error("Failed to unsubscribe from channel \(config.channelName)")
            }

        } catch {
            ArtLog.error("Failed to unsubscribe from channel \(config.channelName): \(error)")
        }
    }


    // MARK: - Reconnect
    public func reconnect() {

        let name = channelConfig.channelName
        guard name != "art_config",
              name != "art_secure" else { return }

        Task {
            if isListening {
                await validateSubscription(process: "presence")
            }

            await subscribe()
        }
    }


    // MARK: - Push
    /// Sends an event on this channel. Returns the SDK-generated `ref_id`
    /// (or `nil` for control channels, which are not ref-tracked).
    ///
    /// On **targeted** channels the call waits for the server's `SA`
    /// acknowledgement and throws `ARTError.ackTimeout` after 50 s.
    @discardableResult
    public func push(
        event: String,
        data: [String: Any],
        options: PushConfig? = nil
    ) async throws -> String? {
        try await sendFrame(event: event, content: data, options: options)
    }

    /// Sends a JSON array payload (used for CRDT `merge` batches).
    public func pushArray(event: String, data: [[String: Any]]) async throws {
        _ = try await sendFrame(event: event, content: data, options: nil)
    }

    /// Builds and sends a push frame for any JSON-compatible content.
    func sendFrame(event: String, content: Any, options: PushConfig?) async throws -> String? {

        await websocketHandler.wait()

        guard let connection = websocketHandler.getConnection() else {
            throw ARTError.notConnected
        }

        let config = channelConfig
        let to = options?.to ?? []
        var messageStr = try ArtJSON.stringify(content)

        // Targeted / secure validation
        if config.channelType == "secure" || config.channelType == "targeted" {
            if to.count != 1 && event != "art_presence" {
                throw ARTError.serverError("Exactly one user must be specified for sending message.")
            }
        }

        if config.channelType == "secure" && event != "art_presence" {

            guard let secureResult = try await websocketHandler.pushForSecureLine(
                event: "secured_public_key",
                data: ["username": to[0]],
                listen: true
            ) as? [String: Any],
            let inner = secureResult["data"] as? [String: Any] else {
                throw ARTError.encryptionError("Could not fetch public key")
            }

            if inner["status"] as? String == "unsuccessfull" {
                throw ARTError.encryptionError(inner["error"] as? String ?? "Unknown error")
            }
            guard let pubKey = inner["public_key"] as? String else {
                throw ARTError.encryptionError("Could not fetch public key")
            }

            messageStr = try await websocketHandler.encrypt(
                messageStr,
                recipientPublicKey: pubKey
            )
        }

        var refId: String?
        var awaitsAck = false

        if !BaseSubscription.controlChannels.contains(config.channelName) {
            let count = stateLock.sync { () -> Int in
                messageCount += 1
                return messageCount
            }
            refId = "\(connection.connectionId)_\(config.channelName)_\(count)"
            // Note: this compares the channel *name* with "secure", so in
            // practice only targeted channels wait for the SA acknowledgement.
            awaitsAck = config.channelType == "targeted" || config.channelName == "secure"
        }

        var message: [String: Any] = [
            "from": connection.connectionId,
            "to": to,
            "channel": config.channelName +
                       (config.channelNamespace.isEmpty ? "" : ":\(config.channelNamespace)"),
            "event": event,
            "content": messageStr,
            // Always sent; `null` when there is no thread.
            "thread_id": options?.threadID.map { $0 as Any } ?? NSNull()
        ]

        if let refId {
            message["ref_id"] = refId
        }

        if let fileMeta = options?.fileMeta, !fileMeta.isEmpty {
            message["file_meta"] = fileMeta.map { $0.jsonObject }
        }

        let frame = try ArtJSON.stringify(message)

        guard awaitsAck, let refId else {
            _ = websocketHandler.sendMessage(frame)
            return refId
        }

        // Register the ACK before sending so a fast `SA` can't be missed.
        let timeoutNs = UInt64(ackTimeoutMs * 1_000_000)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let timer = Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard !Task.isCancelled else { return }
                self.failPendingAck(refId, ARTError.ackTimeout)
            }
            stateLock.sync {
                pendingAcks[refId] = PendingAck(continuation: continuation, timer: timer)
            }
            _ = websocketHandler.sendMessage(frame)
        }
    }


    // MARK: - Override
    open func handleMessage(event: String, payload: [String: Any]) async {}
}
