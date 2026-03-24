// Sources/ARTSdk/Types/SocketTypes.swift

import Foundation

// MARK: - ConnectionDetail
public struct ConnectionDetail {
    public var connectionId: String
    public var instanceId: String
    public var tenantName: String
    public var environment: String
    public var projectKey: String

    public init(
        connectionId: String,
        instanceId: String,
        tenantName: String,
        environment: String,
        projectKey: String
    ) {
        self.connectionId = connectionId
        self.instanceId = instanceId
        self.tenantName = tenantName
        self.environment = environment
        self.projectKey = projectKey
    }
}

// MARK: - PushConfig
public struct PushConfig {
    public var to: [String]

    public init(to: [String] = []) {
        self.to = to
    }
}

// MARK: - CallApiProps
public struct CallApiProps {
    public var method: String
    public var payload: Any?
    public var queryParams: [String: String]?
    public var headers: [String: String]?

    public init(
        method: String = "GET",
        payload: Any? = nil,
        queryParams: [String: String]? = nil,
        headers: [String: String]? = nil
    ) {
        self.method = method
        self.payload = payload
        self.queryParams = queryParams
        self.headers = headers
    }
}

// MARK: - LongPollOptions
public struct LongPollOptions {
    public var endpoint: String
    public var initialConnectionId: String?
    public var getAuthHeaders: () async throws -> [String: String]
    public var onMessages: ([Any]) -> Void
    public var onError: ((Error) -> Void)?
    public var retryDelayMs: Int
    public var emptyPollDelayMs: Int
    public var maxEmptyPollDelayMs: Int

    public init(
        endpoint: String,
        initialConnectionId: String? = nil,
        getAuthHeaders: @escaping () async throws -> [String: String],
        onMessages: @escaping ([Any]) -> Void,
        onError: ((Error) -> Void)? = nil,
        retryDelayMs: Int = 1000,
        emptyPollDelayMs: Int = 500,
        maxEmptyPollDelayMs: Int = 5000
    ) {
        self.endpoint = endpoint
        self.initialConnectionId = initialConnectionId
        self.getAuthHeaders = getAuthHeaders
        self.onMessages = onMessages
        self.onError = onError
        self.retryDelayMs = retryDelayMs
        self.emptyPollDelayMs = emptyPollDelayMs
        self.maxEmptyPollDelayMs = maxEmptyPollDelayMs
    }
}

// MARK: - IWebsocketHandler protocol
public protocol IWebsocketHandler: AnyObject {
    func wait() async
    func sendMessage(_ message: String) -> Bool
    func getConnection() -> ConnectionDetail?
    func encrypt(_ data: String, recipientPublicKey: String) async throws -> String
    func decrypt(_ encryptedHash: String, senderPublicKey: String) async throws -> String
    func pushForSecureLine(event: String, data: Any, listen: Bool) async throws -> Any?
    func removeSubscription(channel: String)
}
