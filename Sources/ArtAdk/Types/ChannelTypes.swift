// Sources/ARTSdk/Types/ChannelTypes.swift

import Foundation

public struct ChannelConfig {
    public var channelName: String
    public var channelNamespace: String
    public var channelType: String
    public var presenceUsers: [String]
    public var snapshot: Any?
    public var subscriptionID: String?

    public init(
        channelName: String,
        channelNamespace: String = "",
        channelType: String = "default",
        presenceUsers: [String] = [],
        snapshot: Any? = nil,
        subscriptionID: String? = nil
    ) {
        self.channelName = channelName
        self.channelNamespace = channelNamespace
        self.channelType = channelType
        self.presenceUsers = presenceUsers
        self.snapshot = snapshot
        self.subscriptionID = subscriptionID
    }
}
