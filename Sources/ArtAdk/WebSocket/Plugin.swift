// Sources/ArtAdk/WebSocket/Plugin.swift
//
// Plugin contract for out-of-tree adapters (e.g. `ArtAdkNotifications`).
// `Adk.use(_:)` installs a plugin and returns its API, which stays
// retrievable via `Adk.plugin(_:as:)`.

import Foundation

/// What a plugin can use from its host `Adk`: the shared connection,
/// the authenticated REST client, credentials, and the gateway origin.
public struct AdkPluginContext {
    /// Subscribes to a channel on the shared connection.
    public let subscribe: (_ channel: String) async throws -> BaseSubscription
    /// Authenticated REST call; returns decoded JSON (`nil` for 204).
    /// Throws `HTTPCallError` for non-2xx responses.
    public let call: (_ endpoint: String, _ options: CallApiProps) async throws -> Any?
    /// Current credentials (throws before `connect()`).
    public let getCredentials: () throws -> AuthenticationConfig
    /// Gateway origin — `Constant.BASE_URL` without a path such as `/ws` —
    /// where adapters should target REST by default.
    public let baseUrl: () -> String

    public init(
        subscribe: @escaping (_ channel: String) async throws -> BaseSubscription,
        call: @escaping (_ endpoint: String, _ options: CallApiProps) async throws -> Any?,
        getCredentials: @escaping () throws -> AuthenticationConfig,
        baseUrl: @escaping () -> String
    ) {
        self.subscribe = subscribe
        self.call = call
        self.getCredentials = getCredentials
        self.baseUrl = baseUrl
    }
}

/// An installable ADK extension. `install` is called once by
/// `Adk.use(_:)`, which returns the plugin's API.
public protocol AdkPlugin {
    associatedtype API
    /// Registry key; the name `Adk.plugin(_:as:)` looks the API up by.
    var name: String { get }
    func install(_ context: AdkPluginContext) -> API
}
