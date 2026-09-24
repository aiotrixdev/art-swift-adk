// Sources/ARTSdk/WebSocket/Subscription.swift

import Foundation

public final class Subscription: BaseSubscription {

    /// Buffered thread-scoped events: threadId → ordered event buffer.
    private var threadBufferStorage: [String: EventBuffer] = [:]

    /// Live `OrchestratorThread`s registered on this subscription.
    private var threads: [String: OrchestratorThread] = [:]

    public override init(
        connectionID: String,
        channelConfig: ChannelConfig,
        websocketHandler: IWebsocketHandler,
        process: String = "subscribe"
    ) {
        super.init(
            connectionID: connectionID,
            channelConfig: channelConfig,
            websocketHandler: websocketHandler,
            process: process
        )
    }

    /// Snapshot of buffered thread-scoped events (threadId → event → entries),
    /// replayed when a thread listener attaches.
    public var threadBuffers: [String: [String: [[String: Any]]]] {
        get { stateLock.sync { threadBufferStorage.mapValues { $0.dictionary } } }
        set { stateLock.sync { threadBufferStorage = newValue.mapValues { EventBuffer($0) } } }
    }

    // MARK: - listen
    /// Drains buffered events, then receives every future non-thread event
    /// as `["event": name, "content": payload]`. Returns a token for
    /// `remove(event: "all", id:)`.
    @discardableResult
    public func listen(_ callback: @escaping ([String: Any]) -> Void) -> UUID {
        let (drained, id) = stateLock.sync { () -> ([(event: String, entry: [String: Any])], UUID) in
            let drained = bufferStorage.drainAll()
            let id = emitter.on("all") { data in
                if let d = data as? [String: Any] { callback(d) }
            }
            return (drained, id)
        }
        deliver(drained, to: callback)
        return id
    }

    // MARK: - bind
    /// Replays buffered payloads for `event`, then receives future ones.
    /// Returns a token for `remove(event:id:)`.
    @discardableResult
    public func bind(event: String, callback: @escaping (Any) -> Void) -> UUID {
        let (drained, id) = stateLock.sync { () -> ([[String: Any]], UUID) in
            (bufferStorage.take(event), emitter.on(event, handler: callback))
        }
        for entry in drained {
            callback(entry["content"] ?? NSNull())
            acknowledge(entry, "CA")
        }
        return id
    }

    // MARK: - remove
    /// Removes every listener for `event` and drops its buffered payloads.
    public func remove(event: String) {
        emitter.off(event)
        stateLock.sync { _ = bufferStorage.take(event) }
    }

    /// Removes the single listener registered with token `id` for `event`
    /// and drops the event's buffered payloads.
    public func remove(event: String, id: UUID) {
        emitter.off(event, id: id)
        stateLock.sync { _ = bufferStorage.take(event) }
    }

    // MARK: - push
    @discardableResult
    public override func push(
        event: String,
        data: [String: Any],
        options: PushConfig? = nil
    ) async throws -> String? {
        try await super.push(event: event, data: data, options: options)
    }

    // MARK: - Storage (channel-scoped)
    //
    // Only on orchestrator-enabled channels, scoped to the channel name.

    /// Uploads a local file scoped to this channel (`config_id` = channel
    /// name). Throws unless the channel is orchestrator-enabled.
    @discardableResult
    public func upload(fileURL: URL, options: UploadOptions = UploadOptions()) async throws -> FileRef {
        try await Storage().upload(fileURL: fileURL, options: try channelScoped(options))
    }

    /// In-memory variant of `upload(fileURL:options:)`.
    @discardableResult
    public func upload(
        data: Data,
        filename: String? = nil,
        contentType: String? = nil,
        options: UploadOptions = UploadOptions()
    ) async throws -> FileRef {
        try await Storage().upload(
            data: data, filename: filename, contentType: contentType,
            options: try channelScoped(options)
        )
    }

    /// Lists files scoped to this channel. Throws unless the channel is
    /// orchestrator-enabled.
    public func listFiles(options: ListOptions = ListOptions()) async throws -> StorageFileList {
        let config = try requireOrchestratorChannel()
        var scoped = options
        scoped.configId = config.channelName
        return try await Storage().listFiles(options: scoped)
    }

    private func channelScoped(_ options: UploadOptions) throws -> UploadOptions {
        let config = try requireOrchestratorChannel()
        var scoped = options
        scoped.configId = config.channelName
        return scoped
    }

    private func requireOrchestratorChannel() throws -> ChannelConfig {
        let config = channelConfig
        guard config.orchestratorEnabled else {
            throw UploadError("Storage requires an orchestrator-enabled channel", step: .validate)
        }
        return config
    }

    // MARK: - Thread-scoped routing
    //
    // Inbound events tagged with a `thread_id` are emitted on
    // `"<threadId>-<event>"` / `"<threadId>-all"` and buffered per thread
    // until a thread listener attaches.

    /// Returns an `OrchestratorThread` for `threadId` on this channel.
    ///
    /// Throws when the channel is not orchestrator-enabled. When `threadId`
    /// matches an existing live thread that instance is returned; otherwise
    /// a fresh thread is created.
    public func thread(threadId: String? = nil) throws -> OrchestratorThread {
        guard channelConfig.orchestratorEnabled else {
            throw ARTError.serverError(
                "Thread works only in case of orchestrator enabled channels"
            )
        }
        return threadUnchecked(threadId: threadId)
    }

    /// Same as `thread(threadId:)` but skips the `orchestratorEnabled`
    /// gate. For callers (e.g. `Orchestrator`) that have already committed
    /// to orchestrator semantics on a dedicated channel.
    public func threadUnchecked(threadId: String? = nil) -> OrchestratorThread {
        stateLock.sync {
            if let threadId,
               let existing = threads[threadId],
               !existing.isDisposed {
                return existing
            }
            let thread = OrchestratorThread(self, threadId)
            threads[thread.threadId] = thread
            return thread
        }
    }

    /// Returns the live `OrchestratorThread` for `threadId`, or `nil`.
    public func getThread(_ threadId: String) -> OrchestratorThread? {
        stateLock.sync { threads[threadId] }
    }

    /// Removes `threadId` from the registry and drops any buffered messages
    /// for it. Invoked by `OrchestratorThread.dispose()`.
    public func unregisterThread(_ threadId: String) {
        stateLock.sync {
            threads.removeValue(forKey: threadId)
            threadBufferStorage.removeValue(forKey: threadId)
        }
    }

    /// Drains buffered events for `threadId` and subscribes `callback` to
    /// every future event tagged with that thread id. Each invocation
    /// receives `["event": name, "content": payload]`. Returns a token for
    /// `detachThreadListener(_:_:id:)` with event `"all"`.
    @discardableResult
    public func attachThreadListener(
        _ threadId: String,
        _ callback: @escaping ([String: Any]) -> Void
    ) -> UUID {
        let (drained, id) = stateLock.sync { () -> ([(event: String, entry: [String: Any])], UUID) in
            var buffer = threadBufferStorage.removeValue(forKey: threadId) ?? EventBuffer()
            let drained = buffer.drainAll()
            let id = emitter.on("\(threadId)-all") { data in
                if let d = data as? [String: Any] { callback(d) }
            }
            return (drained, id)
        }
        deliver(drained, to: callback)
        return id
    }

    /// Subscribes `callback` to a single named `event` within `threadId`,
    /// replaying any buffered payloads for that pair first. Returns a token
    /// for `detachThreadListener(_:_:id:)`.
    @discardableResult
    public func attachThreadBind(
        _ threadId: String,
        _ event: String,
        _ callback: @escaping (Any) -> Void
    ) -> UUID {
        let (drained, id) = stateLock.sync { () -> ([[String: Any]], UUID) in
            let drained = threadBufferStorage[threadId]?.take(event) ?? []
            let id = emitter.on("\(threadId)-\(event)", handler: callback)
            return (drained, id)
        }
        for entry in drained {
            callback(entry["content"] ?? NSNull())
            acknowledge(entry, "CA")
        }
        return id
    }

    /// Removes every listener attached for (`threadId`, `event`) and drops
    /// any buffered payloads for that pair.
    public func detachThreadListener(_ threadId: String, _ event: String) {
        emitter.off("\(threadId)-\(event)")
        stateLock.sync { _ = threadBufferStorage[threadId]?.take(event) }
    }

    /// Removes the single listener registered with token `id` for
    /// (`threadId`, `event`) and drops the pair's buffered payloads.
    public func detachThreadListener(_ threadId: String, _ event: String, id: UUID) {
        emitter.off("\(threadId)-\(event)", id: id)
        stateLock.sync { _ = threadBufferStorage[threadId]?.take(event) }
    }

    private func emitThreadEvent(_ event: String, _ content: Any, _ threadId: String?) {
        let key = (threadId?.isEmpty == false) ? "\(threadId!)-\(event)" : event
        emitter.emit(key, content)
    }

    /// Must be called with `stateLock` held.
    private func bufferEventLocked(_ event: String, _ entry: [String: Any]) {
        if let tid = entry["thread_id"] as? String, !tid.isEmpty {
            threadBufferStorage[tid, default: EventBuffer()].append(event, entry)
        } else {
            bufferStorage.append(event, entry)
        }
    }

    private func deliver(
        _ drained: [(event: String, entry: [String: Any])],
        to callback: ([String: Any]) -> Void
    ) {
        for item in drained {
            callback([
                "event": item.event,
                "content": item.entry["content"] ?? NSNull()
            ])
            acknowledge(item.entry, "CA")
        }
    }

    // MARK: - handleMessage
    public override func handleMessage(event: String, payload: [String: Any]) async {

        let returnFlag = payload["return_flag"] as? String ?? ""

        // Handle SA ack
        if returnFlag == "SA" {
            handleMessageAcks(event: event, returnFlag: returnFlag, data: payload)
            return
        }

        acknowledge(payload, "MA")

        var mutablePayload = payload

        // -------------------------------------------------------
        // SECURE CHANNEL DECRYPT
        // -------------------------------------------------------
        if channelConfig.channelType == "secure" {

            do {
                guard let secureResult = try await websocketHandler.pushForSecureLine(
                    event: "secured_public_key",
                    data: ["username": payload["from_username"] ?? ""],
                    listen: true
                ) as? [String: Any],
                let innerData = secureResult["data"] as? [String: Any] else {
                    ArtLog.error("secured_public_key lookup failed for \(payload["from_username"] ?? "?")")
                    return
                }

                if innerData["status"] as? String == "unsuccessfull" {
                    ArtLog.error("secured_public_key: \(innerData["error"] ?? "unsuccessful")")
                    return
                }
                guard let pubKey = innerData["public_key"] as? String else { return }

                if let encryptedData = mutablePayload["data"] as? String {
                    mutablePayload["data"] = try await websocketHandler.decrypt(
                        encryptedData,
                        senderPublicKey: pubKey
                    )
                }

            } catch {
                ArtLog.error("Failed to decrypt secure message: \(error)")
                return
            }
        }

        // -------------------------------------------------------
        // PARSE CONTENT (`data` arrives as JSON text)
        // -------------------------------------------------------
        var content: Any = [String: Any]()

        if let dataVal = mutablePayload["data"] {
            if let dataStr = dataVal as? String, let parsed = ArtJSON.parse(dataStr) {
                content = parsed
            } else {
                // already a parsed object (e.g. [String: Any])
                content = dataVal
            }
        } else {
            content = mutablePayload
        }

        // -------------------------------------------------------
        // HUMAN-IN-THE-LOOP (HITL)
        // -------------------------------------------------------
        // When the server requests feedback, attach a `reply` closure to the
        // content so consumers can answer (sends `return_flag: "HF"`). The
        // closure is stored under the "reply" key as `(Any) -> Void`; strip it
        // before JSON-serializing content for display.
        let contentType = (content as? [String: Any])?["type"] as? String
        let humanFeedbackRequest =
            returnFlag == "requestFeedback" ||
            event == "human_input_request" ||
            contentType == "human_input_request"
        if humanFeedbackRequest, var dict = content as? [String: Any] {
            // Explicitly typed: an inferred single-expression closure over
            // `self?.…` would be `(Any) -> ()?` and fail the documented
            // `as? (Any) -> Void` cast.
            let reply: (Any) -> Void = { [weak self] replyData in
                self?.sendHumanFeedback(originalReq: payload, replyData: replyData)
            }
            dict["reply"] = reply
            content = dict
        }

        let threadId = mutablePayload["thread_id"] as? String

        // -------------------------------------------------------
        // PRESENCE EVENT
        // -------------------------------------------------------
        if event == "art_presence" {
            emitter.emit("art_presence", content)
            return
        }

        // -------------------------------------------------------
        // TRACE (diagnostic / telemetry) FRAMES
        // -------------------------------------------------------
        // Emitted directly to their listeners, bypassing the subscribed-state
        // gate + the normal buffering path.
        if event == "trace" {
            emitThreadEvent("trace", content, threadId)
            return
        }

        // -------------------------------------------------------
        // EMIT TO LISTENERS (thread-aware)
        // -------------------------------------------------------
        guard isSubscribed else { return }

        // Thread-scoped events route on `"<threadId>-<event>"` keys; flat
        // events keep the plain `event` / `"all"` keys.
        let hasThread = (threadId?.isEmpty == false)
        let eventKey = hasThread ? "\(threadId!)-\(event)" : event
        let allKey   = hasThread ? "\(threadId!)-all"      : "all"

        // Check-or-buffer atomically with listener registration so a frame
        // can't fall between a drain and an attach.
        let (hasSpecific, hasAll) = stateLock.sync { () -> (Bool, Bool) in
            let specific = emitter.listenerCount(eventKey) > 0
            let all = emitter.listenerCount(allKey) > 0
            if !specific && !all {
                // Buffer for later — `thread_id` is copied so the buffer
                // router can replay into the right per-thread queue.
                let keys = [
                    "id", "from", "channel", "to",
                    "pipeline_id", "thread_id", "attempt_id",
                    "interceptor_name", "to_username"
                ]
                var entry: [String: Any] = ["content": content]
                keys.forEach {
                    if let v = mutablePayload[$0] { entry[$0] = v }
                }
                bufferEventLocked(event, entry)
            }
            return (specific, all)
        }

        guard hasSpecific || hasAll else { return }

        if hasSpecific { emitThreadEvent(event, content, threadId) }

        if hasAll {
            emitThreadEvent("all", [
                "event":   event,
                "content": content
            ], threadId)
        }

        acknowledge(mutablePayload, "CA")
    }

    // MARK: - Human-in-the-loop reply
    //
    // Sends a `return_flag: "HF"` frame answering a `human_input_request`,
    // echoing the routing/correlation fields (incl. `root_workflow_id`) from
    // the original request. Invoked via the `reply` closure injected into
    // content in `handleMessage`.
    private func sendHumanFeedback(originalReq: [String: Any], replyData: Any) {
        let conn = websocketHandler.getConnection()
        var reply: [String: Any] = [
            "return_flag": "HF",
            "from": conn?.connectionId ?? "",
        ]

        for key in ["channel", "namespace", "id", "ref_id", "to_username",
                    "from_username", "thread_id", "node_id", "iteration_id",
                    "root_workflow_id", "agent_node_id", "agent_id",
                    "environment_id", "pipeline_id", "attempt_id",
                    "interceptor_name"] {
            if let v = originalReq[key] { reply[key] = v }
        }

        // Reply is routed back to the original sender, if any.
        if ArtJSON.isTruthy(originalReq["from"]), let from = originalReq["from"] {
            reply["to"] = [from]
        } else {
            reply["to"] = [String]()
        }

        // Reply payload is JSON-encoded — strings are quoted.
        do {
            reply["content"] = try ArtJSON.stringify(replyData)
        } catch {
            ArtLog.error("HITL reply is not JSON-serializable: \(error)")
            return
        }

        if let msgStr = try? ArtJSON.stringify(reply) {
            _ = websocketHandler.sendMessage(msgStr)
        }
    }
}
