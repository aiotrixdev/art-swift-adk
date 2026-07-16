// Sources/ARTSdk/Types/ChannelTypes.swift

import Foundation

public struct ChannelConfig {
    public var channelName: String
    public var channelNamespace: String
    public var channelType: String
    public var presenceUsers: [String]
    public var snapshot: Any?
    public var subscriptionID: String?
    /// Whether this channel is orchestrator-enabled (server sends
    /// `IsInterceptorEnabled`; the SDK exposes it under this name). Gates
    /// `Subscription.thread(...)`; the dedicated `orch_com_<id>` channel
    /// used by `Orchestrator` bypasses the gate via `threadUnchecked`.
    public var orchestratorEnabled: Bool

    public init(
        channelName: String,
        channelNamespace: String = "",
        channelType: String = "default",
        presenceUsers: [String] = [],
        snapshot: Any? = nil,
        subscriptionID: String? = nil,
        orchestratorEnabled: Bool = false
    ) {
        self.channelName = channelName
        self.channelNamespace = channelNamespace
        self.channelType = channelType
        self.presenceUsers = presenceUsers
        self.snapshot = snapshot
        self.subscriptionID = subscriptionID
        self.orchestratorEnabled = orchestratorEnabled
    }
}
