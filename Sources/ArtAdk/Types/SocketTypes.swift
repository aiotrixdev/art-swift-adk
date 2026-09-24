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
/// Per-message options for `push`.
public struct PushConfig {
    public var to: [String]
    public var threadID: String?
    public var fileMeta: [FileMeta]

    public init(to: [String] = [], threadID: String? = nil, fileMeta: [FileMeta] = []) {
        self.to = to
        self.threadID = threadID
        self.fileMeta = fileMeta
    }
}

// MARK: - CallApiProps
public struct CallApiProps {
    public var method: String
    public var payload: Any?
    public var queryParams: [String: String]?
    public var headers: [String: String]?
    public var baseUrl: String?
    public var timeoutMs: Int?

    public init(
        method: String = "GET",
        payload: Any? = nil,
        queryParams: [String: String]? = nil,
        headers: [String: String]? = nil,
        baseUrl: String? = nil,
        timeoutMs: Int? = nil
    ) {
        self.method = method
        self.payload = payload
        self.queryParams = queryParams
        self.headers = headers
        self.baseUrl = baseUrl
        self.timeoutMs = timeoutMs
    }
}

public struct UpdateProfileData {
    public var firstName: String?
    public var lastName: String?
    public var email: String?
    public var attributes: [String: Any]?

    public init(
        firstName: String? = nil,
        lastName: String? = nil,
        email: String? = nil,
        attributes: [String: Any]? = nil
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.attributes = attributes
    }

    var payload: [String: Any] {
        var body: [String: Any] = [:]
        if let firstName { body["first_name"] = firstName }
        if let lastName { body["last_name"] = lastName }
        if let email { body["email"] = email }
        if let attributes { body["attributes"] = attributes }
        return body
    }
}

public struct ConnectorField: Equatable {
    public var key: String
    public var label: String
    /// `string`, `secret`, `email`, `number`, `boolean`, `json`, or a
    /// server-defined type.
    public var type: String
    public var placeholder: String?
    public var required: Bool?
    public var description: String?

    public init(
        key: String,
        label: String,
        type: String,
        placeholder: String? = nil,
        required: Bool? = nil,
        description: String? = nil
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.placeholder = placeholder
        self.required = required
        self.description = description
    }
}

/// The authenticated user's profile for one connector.
public struct ConnectorProfile: Equatable {
    public var connectorId: String
    public var provider: String
    public var allowedFields: [ConnectorField]
    public var metadata: [String: String]

    public init(
        connectorId: String,
        provider: String,
        allowedFields: [ConnectorField],
        metadata: [String: String]
    ) {
        self.connectorId = connectorId
        self.provider = provider
        self.allowedFields = allowedFields
        self.metadata = metadata
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
