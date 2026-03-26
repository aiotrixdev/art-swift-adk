// Sources/ARTSdk/WebSocket/BaseSubscription.swift

import Foundation

// MARK: - PendingAck
private struct PendingAck {
    let continuation: CheckedContinuation<String, Error>
    let timer: Task<Void, Never>
}

// MARK: - BaseSubscription
open class BaseSubscription {

    public let connectionID: String
    public var isSubscribed: Bool = false
    public var isListening: Bool = false
    public let websocketHandler: IWebsocketHandler
    public var channelConfig: ChannelConfig
    public var messageBuffer: [String: [[String: Any]]] = [:]
    public var presenceUsers: [String] = []
    public let emitter = EventEmitter()

    private var pendingAcks: [String: PendingAck] = [:]
    private let ackTimeout: Double = 50_000
    private var messageCount: Int = 0

    public init(
        connectionID: String,
        channelConfig: ChannelConfig,
        websocketHandler: IWebsocketHandler,
        process: String = "subscribe"
    ) {
        self.connectionID = connectionID
        self.websocketHandler = websocketHandler
        self.channelConfig = channelConfig
        self.presenceUsers = channelConfig.presenceUsers

        if process == "subscribe" { isSubscribed = true }
        else if process == "presence" { isListening = true }
    }

    // MARK: - Validate subscription
    public func validateSubscription(process: String) async {

        guard !["art_config", "art_secure"].contains(channelConfig.channelName) else { return }

        var channelName = channelConfig.channelName

        if !channelConfig.channelNamespace.isEmpty {
            channelName += ":\(channelConfig.channelNamespace)"
        }

        do {

            let config = try await subscribe_to_channel(
                channel: channelName,
                process: process,
                websocketHandler: websocketHandler
            )

            channelConfig = config

            if process == "presence" {
                isListening = true
            }

        } catch {

            LogTracer.log("[ART] validateSubscription error: \(error)")
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

            guard let self,
                  let data = payload as? [String: Any],
                  let usernames = data["usernames"] as? [String],
                  (data["error"] as? Bool ?? false) == false else { return }

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

            _ = try await unsubscribe_from_channel(
                channel: self.channelConfig.channelName,
                subscriptionID: self.channelConfig.subscriptionID ?? "",
                process: "presence",
                websocketHandler: self.websocketHandler
            )
        }
    }
    
    
    // MARK: - ACK
    public func acknowledge(_ request: [String: Any], _ returnFlag: String) {

        guard channelConfig.channelType == "targeted" ||
              channelConfig.channelType == "secure" else { return }

        guard let channel = request["channel"] as? String,
              !["art_config", "art_secure", "art_presence"].contains(channel) else { return }

        var response: [String: Any] = [
            "channel": channel,
            "return_flag": returnFlag
        ]

        let keys = [
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

        if let data = try? JSONSerialization.data(withJSONObject: response),
           let str = String(data: data, encoding: .utf8) {

            _ = websocketHandler.sendMessage(str)
        }
    }

    // MARK: - Handle ACK
    public func handleMessageAcks(
        event: String,
        returnFlag: String,
        data: [String: Any]
    ) {

        guard returnFlag == "SA",
              let refId = data["ref_id"] as? String else { return }

        if let ack = pendingAcks[refId] {

            ack.timer.cancel()
            ack.continuation.resume(returning: refId)

            pendingAcks.removeValue(forKey: refId)
        }
    }
    
    // MARK: - Subscribe
    public func subscribe() async {

        guard !["art_config", "art_secure"].contains(channelConfig.channelName) else {
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

            LogTracer.log("[ART] subscribe error: \(error)")
            isSubscribed = false
        }
    }
    
    // MARK: - Unsubscribe
    public func unsubscribe() async {

        guard let subID = channelConfig.subscriptionID else { return }

        do {

            let ok = try await unsubscribe_from_channel(
                channel: channelConfig.channelName,
                subscriptionID: subID,
                process: "subscribe",
                websocketHandler: websocketHandler
            )

            if ok {
                websocketHandler.removeSubscription(channel: channelConfig.channelName)
            }

        } catch {
            LogTracer.log("[ART] unsubscribe error: \(error)")
        }
    }
    
    
    // MARK: - Reconnect
    public func reconnect() {

        guard channelConfig.channelName != "art_config",
              channelConfig.channelName != "art_secure" else { return }

        Task {
            if isListening {
                await validateSubscription(process: "presence")
            }

            await subscribe()
        }
    }
    
    
    // MARK: - Push
    public func push(
        event: String,
        data: [String: Any],
        options: PushConfig? = nil
    ) async throws {

        await websocketHandler.wait()

        guard let connection = websocketHandler.getConnection() else {
            throw ARTError.notConnected
        }

        let to = options?.to ?? []
    
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        var messageStr = String(data: jsonData, encoding: .utf8) ?? "{}"

        // Targeted / secure validation
        if channelConfig.channelType == "secure" || channelConfig.channelType == "targeted" {
            if to.count != 1 && event != "art_presence" {
                throw ARTError.serverError("Exactly one user must be specified for targeted/secure channel")
            }
        }
        

        if channelConfig.channelType == "secure" && event != "art_presence" {

            guard let secureResult = try await websocketHandler.pushForSecureLine(
                event: "secured_public_key",
                data: ["username": to[0]],
                listen: true
            ) as? [String: Any],
            let inner = secureResult["data"] as? [String: Any],
            let pubKey = inner["public_key"] as? String else {
                throw ARTError.encryptionError("Could not fetch public key")
            }

            if inner["status"] as? String == "unsuccessfull" {
                throw ARTError.encryptionError(inner["error"] as? String ?? "Unknown error")
            }

            messageStr = try await websocketHandler.encrypt(
                messageStr,
                recipientPublicKey: pubKey
            )
        }

        var refId: String?

        if !["art_config","art_secure","art_presence"].contains(channelConfig.channelName) {
            messageCount += 1
            refId = "\(connection.connectionId)_\(channelConfig.channelName)_\(messageCount)"
        }

        var message: [String: Any] = [
            "from": connection.connectionId,
            "to": to,
            "channel": channelConfig.channelName +
                       (channelConfig.channelNamespace.isEmpty ? "" : ":\(channelConfig.channelNamespace)"),
            "event": event,
            "content": messageStr
        ]

        if let refId {
            message["ref_id"] = refId
        }


        if let msgData = try? JSONSerialization.data(withJSONObject: message),
           let msgStr = String(data: msgData, encoding: .utf8) {

            LogTracer.printJSONString(
                msgStr,
                title: "Pushing Message Data=============>"
            )
            _ = websocketHandler.sendMessage(msgStr)
        }
    }

    public func pushArray(event: String, data: [[String: Any]]) async throws {

        await websocketHandler.wait()

        guard let connection = websocketHandler.getConnection() else {
            throw ARTError.notConnected
        }

        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let messageStr = String(data: jsonData, encoding: .utf8) ?? "[]"

        messageCount += 1
        let refId = "\(connection.connectionId)_\(channelConfig.channelName)_\(messageCount)"

        let message: [String: Any] = [
            "from": connection.connectionId,
            "to": [],
            "channel": channelConfig.channelName +
                       (channelConfig.channelNamespace.isEmpty ? "" : ":\(channelConfig.channelNamespace)"),
            "event": event,
            "content": messageStr,
            "ref_id": refId
        ]

        if let msgData = try? JSONSerialization.data(withJSONObject: message),
           let msgStr = String(data: msgData, encoding: .utf8) {
            LogTracer.printJSONString(msgStr, title: "CRDT Push")
            _ = websocketHandler.sendMessage(msgStr)
        }
    }


    // MARK: - Override
    open func handleMessage(event: String, payload: [String: Any]) async {}
}
