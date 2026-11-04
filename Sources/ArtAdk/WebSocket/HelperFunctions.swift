// Sources/ARTSdk/WebSocket/HelperFunctions.swift

import Foundation

// MARK: - subscribe_to_channel
public func subscribe_to_channel(
    channel: String,
    process: String,
    websocketHandler: IWebsocketHandler
) async throws -> ChannelConfig {
    try await websocketHandler.wait()

    let subscriptionChannelName = process == "subscribe" ? "channel-subscribe" : "channel-presence"

    guard let result = try await websocketHandler.pushForSecureLine(
        event: subscriptionChannelName,
        data: ["channel": channel],
        listen: true
    ) else {
        throw ARTError.channelNotFound(channel)
    }

    guard let wrapper = result as? [String: Any],
          let data = wrapper["data"] as? [String: Any] else {
        throw ARTError.serverError("Invalid subscribe response shape")
    }

    if let status = data["status"] as? String, status == "not-OK" {
        throw ARTError.serverError(rejection(data, "The channel subscription was rejected."))
    }

    guard let rawData = data["channelConfig"] as? [String: Any] else {
        throw ARTError.serverError("The server did not return a channel configuration.")
    }

    let snapshot = data["snapshot"]
    let presenceUsers    = data["presenceUsers"]   as? [String] ?? []
    let channelName      = data["channel"]        as? String ?? channel
    let channelNamespace = data["channelNamespace"] as? String ?? ""
    let subscriptionID   = data["subscriptionID"]  as? String
    return ChannelConfig(
        channelName:      channelName,
        channelNamespace: channelNamespace,
        channelType:      rawData["TypeofChannel"] as? String ?? "default",
        presenceUsers:    presenceUsers,
        snapshot:         snapshot,
        subscriptionID:   subscriptionID,
        orchestratorEnabled: (rawData["IsInterceptorEnabled"] as? NSNumber)?.boolValue ?? false,
        configurationID:  ArtJSON.string(data["configurationID"])
    )
}

/// The server's `error` text, else `fallback`.
private func rejection(_ data: [String: Any], _ fallback: String) -> String {
    let error = data["error"] as? String ?? ""
    return error.isEmpty ? fallback : error
}

// MARK: - unsubscribe_from_channel
public func unsubscribe_from_channel(
    channel: String,
    subscriptionID: String,
    process: String,
    websocketHandler: IWebsocketHandler
) async throws -> Bool {
    try await websocketHandler.wait()

    let channelName = process == "subscribe" ? "channel-unsubscribe" : "presence-unsubscribe"

    guard let result = try await websocketHandler.pushForSecureLine(
        event: channelName,
        data: ["channel": channel, "subscriptionID": subscriptionID],
        listen: true
    ) else { return false }

    guard let wrapper = result as? [String: Any],
          let data = wrapper["data"] as? [String: Any] else { return false }

    if let status = data["status"] as? String, status == "not-OK" {
        throw ARTError.serverError(rejection(data, "The channel request was rejected."))
    }

    return true
}

// MARK: - get_interceptor_config
public func get_interceptor_config(
    interceptor: String,
    websocketHandler: IWebsocketHandler
) async throws -> Any? {
    try await websocketHandler.wait()

    guard let result = try await websocketHandler.pushForSecureLine(
        event: "interceptor-subscribe",
        data: ["interceptor": interceptor],
        listen: true
    ) else { return nil }

    guard let wrapper = result as? [String: Any],
          let data = wrapper["data"] as? [String: Any] else { return nil }

    if let status = data["status"] as? String, status == "not-OK" {
        throw ARTError.serverError(rejection(data, "The interceptor subscription was rejected."))
    }

    return data["interceptorConfig"]
}
