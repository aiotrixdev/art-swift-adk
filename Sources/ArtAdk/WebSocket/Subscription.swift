// Sources/ARTSdk/WebSocket/Subscription.swift

import Foundation

public final class Subscription: BaseSubscription {

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

    // MARK: - listen
    public func listen(_ callback: @escaping ([String: Any]) -> Void) {

        for (evt, msgs) in messageBuffer {
            for reqData in msgs {
                callback([
                    "event": evt,
                    "content": reqData["content"] ?? NSNull()
                ])
                acknowledge(reqData, "CA")
            }
        }
        messageBuffer.removeAll()

        _ = emitter.on("all") { data in
            if let d = data as? [String: Any] {
                callback(d)
            }
        }
    }

    // MARK: - bind
    public func bind(event: String, callback: @escaping (Any) -> Void) {

        if let msgs = messageBuffer[event] {
            for reqData in msgs {
                callback(reqData["content"] ?? NSNull())
                acknowledge(reqData, "CA")
            }
            messageBuffer.removeValue(forKey: event)
        }

        _ = emitter.on(event, handler: callback)
    }

    // MARK: - remove
    public func remove(event: String) {
        emitter.off(event)
        messageBuffer.removeValue(forKey: event)
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

    // MARK: - Thread-scoped routing
    //
    // Buffers and listener wiring for thread-scoped (orchestrator) events.
    // Inbound events tagged with a `thread_id` are emitted on the keys
    // `"<threadId>-<event>"` / `"<threadId>-all"`, mirroring the Flutter
    // `Subscription` thread plumbing. `OrchestratorThread` (added with the
    // orchestrator layer) drives these via the attach/detach helpers.

    /// Buffered thread-scoped events keyed by `threadId → event → entries`,
    /// replayed when a thread listener attaches.
    public var threadBuffers: [String: [String: [[String: Any]]]] = [:]

    /// Live `OrchestratorThread`s registered on this subscription, keyed by
    /// thread id.
    private var threads: [String: OrchestratorThread] = [:]

    /// Returns an `OrchestratorThread` for `threadId` on this channel.
    ///
    /// Throws when the channel is not orchestrator-enabled. When `threadId`
    /// matches an existing live thread that instance is returned; otherwise
    /// a fresh thread is created.
    public func thread(threadId: String? = nil) throws -> OrchestratorThread {
        guard channelConfig.orchestratorEnabled else {
            throw ARTError.serverError(
                "Channel \(channelConfig.channelName) is not orchestrator-enabled"
            )
        }
        return threadUnchecked(threadId: threadId)
    }

    /// Same as `thread(threadId:)` but skips the `orchestratorEnabled`
    /// gate. For callers (e.g. `Orchestrator`) that have already committed
    /// to orchestrator semantics on a dedicated channel.
    public func threadUnchecked(threadId: String? = nil) -> OrchestratorThread {
        if let threadId,
           let existing = threads[threadId],
           !existing.isDisposed {
            return existing
        }
        let thread = OrchestratorThread(self, threadId)
        threads[thread.threadId] = thread
        return thread
    }

    /// Returns the live `OrchestratorThread` for `threadId`, or `nil`.
    public func getThread(_ threadId: String) -> OrchestratorThread? {
        threads[threadId]
    }

    /// Removes `threadId` from the registry and drops any buffered messages
    /// for it. Invoked by `OrchestratorThread.dispose()`.
    public func unregisterThread(_ threadId: String) {
        threads.removeValue(forKey: threadId)
        threadBuffers.removeValue(forKey: threadId)
    }

    /// Drains buffered events for `threadId` and subscribes `callback` to
    /// every future event tagged with that thread id. Each invocation
    /// receives a map with `event` and `content` keys.
    public func attachThreadListener(
        _ threadId: String,
        _ callback: @escaping ([String: Any]) -> Void
    ) {
        if let buf = threadBuffers[threadId] {
            for (evt, msgs) in buf {
                for reqData in msgs {
                    callback([
                        "event": evt,
                        "content": reqData["content"] ?? NSNull()
                    ])
                    acknowledge(reqData, "CA")
                }
            }
            threadBuffers.removeValue(forKey: threadId)
        }

        _ = emitter.on("\(threadId)-all") { data in
            if let d = data as? [String: Any] {
                callback(d)
            }
        }
    }

    /// Subscribes `callback` to a single named `event` within `threadId`,
    /// replaying any buffered payloads for that pair first.
    public func attachThreadBind(
        _ threadId: String,
        _ event: String,
        _ callback: @escaping (Any) -> Void
    ) {
        if var buf = threadBuffers[threadId], let msgs = buf[event] {
            for reqData in msgs {
                callback(reqData["content"] ?? NSNull())
                acknowledge(reqData, "CA")
            }
            buf.removeValue(forKey: event)
            threadBuffers[threadId] = buf
        }

        _ = emitter.on("\(threadId)-\(event)", handler: callback)
    }

    /// Removes the listener(s) attached for (`threadId`, `event`) and drops
    /// any buffered payloads for that pair.
    public func detachThreadListener(_ threadId: String, _ event: String) {
        emitter.off("\(threadId)-\(event)")
        threadBuffers[threadId]?.removeValue(forKey: event)
    }

    private func emitThreadEvent(_ event: String, _ content: Any, _ threadId: String?) {
        let key = (threadId?.isEmpty == false) ? "\(threadId!)-\(event)" : event
        emitter.emit(key, content)
    }

    private func bufferEvent(_ event: String, _ entry: [String: Any]) {
        if let tid = entry["thread_id"] as? String, !tid.isEmpty {
            threadBuffers[tid, default: [:]][event, default: []].append(entry)
        } else {
            messageBuffer[event, default: []].append(entry)
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
                let innerData = secureResult["data"] as? [String: Any],
                let pubKey = innerData["public_key"] as? String else { return }

                if innerData["status"] as? String == "unsuccessfull" { return }

                if let encryptedData = mutablePayload["data"] as? String {
                    mutablePayload["data"] = try await websocketHandler.decrypt(
                        encryptedData,
                        senderPublicKey: pubKey
                    )
                }

            } catch {
                return
            }
        }

        // -------------------------------------------------------
        // PARSE CONTENT-------------------------------------------------
        var content: Any = [:]

        if let dataVal = mutablePayload["data"] {
            // payload has 'data' key — parse it
            if let dataStr = dataVal as? String,
               let jsonData = dataStr.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) {
                content = parsed
            } else {
                // already a parsed object (e.g. [String: Any])
                content = dataVal
            }
        } else {
            // fallback: try parsing the whole payload
            if let jsonData = try? JSONSerialization.data(withJSONObject: mutablePayload),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) {
                content = parsed
            }
        }

        // -------------------------------------------------------
        // HUMAN-IN-THE-LOOP (HITL)
        // -------------------------------------------------------
        // When the server requests feedback, attach a `reply` closure to the
        // content so consumers can answer (sends `return_flag: "HF"`). The
        // closure is stored under the "reply" key as `(Any) -> Void`; strip it
        // before JSON-serializing content for display. Mirrors
        // js-adk-common subscription.ts (requestFeedback / root_workflow_id).
        let contentType = (content as? [String: Any])?["type"] as? String
        let humanFeedbackRequest =
            returnFlag == "requestFeedback" ||
            event == "human_input_request" ||
            contentType == "human_input_request"
        if humanFeedbackRequest, var dict = content as? [String: Any] {
            dict["reply"] = { [weak self] (replyData: Any) in
                self?.sendHumanFeedback(originalReq: payload, replyData: replyData)
            }
            content = dict
        }

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
        // gate + the normal buffering path (mirrors js-adk-common
        // subscription.ts). Consumers attach via `AgentThread.listenTrace` /
        // `OrchestratorThread.listenTrace`.
        if event == "trace" {
            emitThreadEvent("trace", content, mutablePayload["thread_id"] as? String)
            return
        }

        // -------------------------------------------------------
        // EMIT TO LISTENERS (thread-aware)
        // -------------------------------------------------------
        guard isSubscribed else { return }

        // Thread-scoped events route on `"<threadId>-<event>"` keys; flat
        // events keep the plain `event` / `"all"` keys.
        let threadId = mutablePayload["thread_id"] as? String
        let hasThread = (threadId?.isEmpty == false)
        let eventKey = hasThread ? "\(threadId!)-\(event)" : event
        let allKey   = hasThread ? "\(threadId!)-all"      : "all"

        let hasSpecific = emitter.listenerCount(eventKey) > 0
        let hasAll      = emitter.listenerCount(allKey) > 0

        if hasSpecific || hasAll {

            if hasSpecific { emitThreadEvent(event, content, threadId) }

            if hasAll {
                emitThreadEvent("all", [
                    "event":   event,
                    "content": content
                ], threadId)
            }

            acknowledge(mutablePayload, "CA")

        } else {

            // Buffer for later — `thread_id` is copied so the buffer router
            // can replay into the right per-thread queue.
            let keys = [
                "id", "from", "channel", "to",
                "pipeline_id", "thread_id", "attempt_id",
                "interceptor_name", "to_username"
            ]

            var entry: [String: Any] = ["content": content]
            keys.forEach {
                if let v = mutablePayload[$0] { entry[$0] = v }
            }

            bufferEvent(event, entry)
        }
    }

    // MARK: - Human-in-the-loop reply
    //
    // Sends a `return_flag: "HF"` frame answering a `human_input_request`,
    // echoing the routing/correlation fields (incl. `root_workflow_id`) from
    // the original request. Invoked via the `reply` closure injected into
    // content in `handleMessage`. Mirrors js-adk-common subscription.ts
    // `sendHumanFeedback`.
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

        // Reply is routed back to the original sender.
        if let from = originalReq["from"] {
            reply["to"] = [from]
        }

        // Reply payload is JSON-encoded into `content` (mirrors JSON.stringify).
        if JSONSerialization.isValidJSONObject(replyData),
           let data = try? JSONSerialization.data(withJSONObject: replyData),
           let str = String(data: data, encoding: .utf8) {
            reply["content"] = str
        } else if let str = replyData as? String {
            reply["content"] = str
        } else {
            reply["content"] = "\(replyData)"
        }

        if let msgData = try? JSONSerialization.data(withJSONObject: reply),
           let msgStr = String(data: msgData, encoding: .utf8) {
            _ = websocketHandler.sendMessage(msgStr)
        }
    }
}
