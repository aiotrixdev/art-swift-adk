// Sources/ARTSdk/Types/SocketTypes.swift

import Foundation

// MARK: - ConnectionError
/// A failure of the client's connection to the ART server.
///
/// It does not mean that a server-side execution failed: once the client is
/// disconnected it cannot tell whether a submitted request completed.
///
/// Delivered by the `connectionFailed` event, and thrown by connection
/// waits, sends and control requests once the connection has failed. After
/// a failure the SDK stops reconnecting on its own; fix the cause and call
/// `Adk.connect()` again.
///
/// `code` is one of:
/// - `CONNECTION_TIMEOUT`: the connection or a control request did not
///   become ready in time.
/// - `CONNECTION_LOST`: the connection dropped before a message could be
///   sent, or could not be restored.
/// - `CONNECTION_CLOSED` / `CONNECTION_PAUSED`: the app closed or paused the
///   connection.
/// - `CONNECTION_CANCELLED`: a newer connection attempt replaced this one.
/// - `CONNECTION_AUTHORIZATION_FAILED`: the connection's authorisation could
///   not be renewed.
/// - `AUTHENTICATION_FAILED`: the credentials are missing or were rejected
///   (`status` holds the HTTP status when the server rejected them).
/// - `ACK_TIMEOUT`: the server did not acknowledge a message.
/// - `CONNECTION_MINUTES_LIMIT_EXCEEDED` / `CONCURRENT_LIMIT_EXCEEDED`: a
///   server billing or concurrency limit was reached.
public struct ConnectionError: Error, LocalizedError, CustomStringConvertible {
    /// Readable description of the failure.
    public let message: String
    /// Machine-readable reason, e.g. `CONNECTION_LOST`.
    public let code: String
    /// HTTP status behind the failure, when there was one.
    public let status: Int?

    public init(_ message: String, code: String, status: Int? = nil) {
        self.message = message
        self.code = code
        self.status = status
    }

    public var errorDescription: String? { message }

    public var description: String {
        if let status { return "\(code) (\(status)): \(message)" }
        return "\(code): \(message)"
    }
}

// MARK: - AuthenticationFailedDetail
/// Payload of the `authenticationFailed` event.
///
/// Emitted when the server rejects the credentials, or when a token renewal
/// fails while reconnecting or while renewing the connection's
/// authorisation. Automatic reconnection stops; update the credentials and
/// call `Adk.connect()` again.
public struct AuthenticationFailedDetail {
    /// HTTP status of the rejection (401 or 403), or `0` when the failure
    /// was not a credential rejection (for example a network error).
    public let status: Int
    /// Readable description of the failure.
    public let error: String

    public init(status: Int, error: String) {
        self.status = status
        self.error = error
    }
}

// MARK: - ExecutionOrigin
/// Where an agent or orchestrator request was started, sent as
/// `execution_origin`.
public enum ExecutionOrigin: String, Sendable {
    /// The request comes from the ART playground.
    case playground
}

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
    /// Files the request refers to, sent as `file_meta`.
    public var fileMeta: [MediaRef]
    /// Where the request was started, sent as `execution_origin`. Leave it
    /// `nil` for ordinary requests.
    public var executionOrigin: ExecutionOrigin?

    public init(
        to: [String] = [],
        threadID: String? = nil,
        fileMeta: [MediaRef] = [],
        executionOrigin: ExecutionOrigin? = nil
    ) {
        self.to = to
        self.threadID = threadID
        self.fileMeta = fileMeta
        self.executionOrigin = executionOrigin
    }
}

// MARK: - CallApiProps
public struct CallApiProps {
    public var method: String
    /// Request body. A `FormDataPayload` is sent as `multipart/form-data`;
    /// anything else is encoded as JSON.
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

// MARK: - FormDataPayload
/// A `multipart/form-data` request body for `CallApiProps.payload`.
public struct FormDataPayload {
    /// Text fields of the form.
    public var fields: [String: String]
    /// File parts of the form.
    public var files: [FormDataFile]

    public init(fields: [String: String] = [:], files: [FormDataFile] = []) {
        self.fields = fields
        self.files = files
    }
}

/// A file part of a `FormDataPayload`.
public struct FormDataFile {
    /// Form field name.
    public var field: String
    /// File contents.
    public var data: Data
    /// File name sent with the part.
    public var filename: String
    /// MIME type of the part; `application/octet-stream` when `nil`.
    public var contentType: String?

    public init(field: String, data: Data, filename: String, contentType: String? = nil) {
        self.field = field
        self.data = data
        self.filename = filename
        self.contentType = contentType
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
    /// Called after every poll the server answered (with or without
    /// messages).
    var onResponse: (() -> Void)?

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
    /// Waits until the connection is ready. Throws the `ConnectionError`
    /// once the connection has failed; a wait that outlasts
    /// `AdkConfig.connectionTimeoutMs` fails the connection with
    /// `CONNECTION_TIMEOUT`.
    func wait() async throws
    /// Makes sure the server authorises the connection with the current
    /// access token before a channel operation: renews the token when it is
    /// about to expire and, when it changed, renews the connection's
    /// authorisation. Throws when the token cannot be renewed or the server
    /// rejects it; a rejection also stops automatic reconnection.
    func ensureAuthorization() async throws
    /// Sends a raw JSON frame. Messages are never queued for replay: throws
    /// a `ConnectionError` (`CONNECTION_LOST`, or the failure that ended the
    /// connection) when there is no connection to send on.
    @discardableResult
    func sendMessage(_ message: String) throws -> Bool
    func getConnection() -> ConnectionDetail?
    func encrypt(_ data: String, recipientPublicKey: String) async throws -> String
    func decrypt(_ encryptedHash: String, senderPublicKey: String) async throws -> String
    /// Sends a request on the internal `art_secure` line once the connection
    /// is ready. With `listen`, returns the server's reply, or throws a
    /// `ConnectionError` (`CONNECTION_TIMEOUT` when no reply arrives within
    /// `AdkConfig.connectionTimeoutMs`, or the failure that ends the
    /// connection meanwhile).
    func pushForSecureLine(event: String, data: Any, listen: Bool) async throws -> Any?
    func removeSubscription(channel: String)
    /// Calls `listener` when the connection fails (the `connectionFailed`
    /// event). Returns an id for `offConnectionFailure(_:)`.
    @discardableResult
    func onConnectionFailure(_ listener: @escaping (ConnectionError) -> Void) -> UUID
    /// Removes a listener added with `onConnectionFailure(_:)`.
    func offConnectionFailure(_ id: UUID)
}
