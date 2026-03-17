//// Sources/ARTSdk/WebSocket/Subscription.swift
//
//
//import Foundation
//
//public final class Subscription: BaseSubscription {
//
//    public override init(
//        connectionID: String,
//        channelConfig: ChannelConfig,
//        websocketHandler: IWebsocketHandler,
//        process: String = "subscribe"
//    ) {
//        super.init(
//            connectionID: connectionID,
//            channelConfig: channelConfig,
//            websocketHandler: websocketHandler,
//            process: process
//        )
//    }
//
//    // MARK: - listen
//    public func listen(_ callback: @escaping ([String: Any]) -> Void) {
//
//        for (evt, msgs) in messageBuffer {
//            for reqData in msgs {
//                callback([
//                    "event": evt,
//                    "content": reqData["content"] ?? NSNull()
//                ])
//                acknowledge(reqData, "CA")
//            }
//        }
//
//        messageBuffer.removeAll()
//
//        _ = emitter.on("all") { data in
//            if let d = data as? [String: Any] {
//                callback(d)
//            }
//        }
//    }
//
//    // MARK: - bind
//    public func bind(event: String, callback: @escaping (Any) -> Void) {
//
//        if let msgs = messageBuffer[event] {
//            for reqData in msgs {
//                callback(reqData["content"] ?? NSNull())
//                acknowledge(reqData, "CA")
//            }
//            messageBuffer.removeValue(forKey: event)
//        }
//
//        _ = emitter.on(event, handler: callback)
//    }
//
//    // MARK: - remove
//    public func remove(event: String) {
//        emitter.off(event)
//        messageBuffer.removeValue(forKey: event)
//    }
//
//    // MARK: - push
//    public override func push(
//        event: String,
//        data: [String: Any],
//        options: PushConfig? = nil
//    ) async throws {
//
//        try await super.push(event: event, data: data, options: options)
//    }
//
//    // MARK: - handleMessage
//    public override func handleMessage(event: String, payload: [String: Any]) async {
//
//        let returnFlag = payload["return_flag"] as? String ?? ""
//
//        // Handle ACK
//        if returnFlag == "SA" {
//            handleMessageAcks(event: event, returnFlag: returnFlag, data: payload)
//            return
//        }
//
//        acknowledge(payload, "MA")
//
//        var mutablePayload = payload
//
//        //-------------------------------------------------------
//        // SECURE CHANNEL DECRYPT
//        //-------------------------------------------------------
//
//        if channelConfig.channelType == "secure" {
//
//            do {
//
//                guard let secureResult = try await websocketHandler.pushForSecureLine(
//                    event: "secured_public_key",
//                    data: ["username": payload["from_username"] ?? ""],
//                    listen: true
//                ) as? [String: Any],
//                let innerData = secureResult["data"] as? [String: Any],
//                let pubKey = innerData["public_key"] as? String else { return }
//
//                if innerData["status"] as? String == "unsuccessfull" { return }
//
//                if let encrypted = payload["content"] as? String {
//
//                    mutablePayload["content"] =
//                        try await websocketHandler.decrypt(
//                            encrypted,
//                            senderPublicKey: pubKey
//                        )
//                }
//
//            } catch {
//                print("[ART] Decryption error:", error)
//                return
//            }
//        }
//
//        //-------------------------------------------------------
//        // PARSE CONTENT
//        //-------------------------------------------------------
//
//        var content: Any = [:]
//
//        if let dataStr = mutablePayload["content"] as? String,
//           let jsonData = dataStr.data(using: .utf8),
//           let parsed = try? JSONSerialization.jsonObject(with: jsonData) {
//
//            content = parsed
//
//        } else if let obj = mutablePayload["content"] {
//            content = obj
//        }
//
//        //-------------------------------------------------------
//        // PRESENCE EVENT
//        //-------------------------------------------------------
//
//        if event == "art_presence" {
//            emitter.emit("art_presence", content)
//            return
//        }
//
//        guard isSubscribed else { return }
//
//        let hasSpecific = emitter.listenerCount(event) > 0
//        let hasAll = emitter.listenerCount("all") > 0
//
//        if hasSpecific || hasAll {
//
//            if hasSpecific { emitter.emit(event, content) }
//
//            if hasAll {
//                emitter.emit("all", [
//                    "event": event,
//                    "content": content
//                ])
//            }
//
//            acknowledge(mutablePayload, "CA")
//
//        } else {
//
//            let keys = [
//                "id",
//                "from",
//                "channel",
//                "to",
//                "pipeline_id",
//                "attempt_id",
//                "interceptor_name",
//                "to_username"
//            ]
//
//            var entry: [String: Any] = ["content": content]
//
//            keys.forEach {
//                if let v = mutablePayload[$0] { entry[$0] = v }
//            }
//
//            messageBuffer[event, default: []].append(entry)
//        }
//    }
//}


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
    public override func push(
        event: String,
        data: [String: Any],
        options: PushConfig? = nil
    ) async throws {
        try await super.push(event: event, data: data, options: options)
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
                print("[ART] Decryption error:", error)
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
        // PRESENCE EVENT
        // -------------------------------------------------------
        if event == "art_presence" {
            emitter.emit("art_presence", content)
            return
        }

        // -------------------------------------------------------
        // EMIT TO LISTENERS
        // -------------------------------------------------------
        guard isSubscribed else { return }

        let hasSpecific = emitter.listenerCount(event) > 0
        let hasAll      = emitter.listenerCount("all") > 0

        if hasSpecific || hasAll {

            if hasSpecific { emitter.emit(event, content) }

            if hasAll {
                emitter.emit("all", [
                    "event":   event,
                    "content": content
                ])
            }

            acknowledge(mutablePayload, "CA")

        } else {

            // Buffer for later )
            let keys = [
                "id", "from", "channel", "to",
                "pipeline_id", "attempt_id",
                "interceptor_name", "to_username"
            ]

            var entry: [String: Any] = ["content": content]
            keys.forEach {
                if let v = mutablePayload[$0] { entry[$0] = v }
            }

            messageBuffer[event, default: []].append(entry)
        }
    }
}
