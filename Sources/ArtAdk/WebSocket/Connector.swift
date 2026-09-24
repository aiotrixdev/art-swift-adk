// Sources/ArtAdk/WebSocket/Connector.swift
//
// Connector-scoped profile for the authenticated ART user. Talks to the
// server over the `art_secure` line with the `connector-profile` event
// (`action: "describe" | "update"`).

import Foundation

/// Error raised by `Connector` (unknown connector, disallowed field,
/// unsuccessful server response).
public struct ConnectorError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A connector-scoped profile for the currently authenticated ART user.
/// Created via `Adk.connector(_:)`.
public final class Connector {

    public let connectorId: String
    private let handler: IWebsocketHandler
    private let lock = ArtLock()
    private var profileTask: Task<ConnectorProfile, Error>

    /// Starts the describe lookup immediately so `connector(id)` can stay
    /// synchronous.
    init(connectorId: String, handler: IWebsocketHandler) throws {
        guard !connectorId.isEmpty else {
            throw ConnectorError("connectorId must be a non-empty string")
        }
        self.connectorId = connectorId
        self.handler = handler
        self.profileTask = Task {
            try Connector.toProfile(
                try await Connector.request(handler, connectorId, action: "describe", metadata: nil),
                connectorId: connectorId
            )
        }
    }

    /// The connector, its allowed metadata fields, and the user's current
    /// values.
    public func profile() async throws -> ConnectorProfile {
        try await lock.sync { profileTask }.value
    }

    /// Partially updates the user's metadata for this connector. Every key
    /// must be one of the connector's `allowedFields`; the server repeats
    /// all validation before persisting the merged profile.
    @discardableResult
    public func updateProfile(_ metadata: [String: String]) async throws -> ConnectorProfile {
        let current = try await profile()
        let allowed = Set(current.allowedFields.map(\.key))
        for key in metadata.keys.sorted() where !allowed.contains(key) {
            throw ConnectorError("Metadata field \"\(key)\" is not allowed for connector \(connectorId)")
        }

        let updated = try Connector.toProfile(
            try await Connector.request(handler, connectorId, action: "update", metadata: metadata),
            connectorId: connectorId
        )
        lock.sync { profileTask = Task { updated } }
        return updated
    }

    // MARK: - Wire

    static func request(
        _ handler: IWebsocketHandler,
        _ connectorId: String,
        action: String,
        metadata: [String: String]?
    ) async throws -> [String: Any] {
        await handler.wait()
        var payload: [String: Any] = [
            "action": action,
            "connector_id": connectorId,
        ]
        if let metadata { payload["metadata"] = metadata }

        let result = try await handler.pushForSecureLine(event: "connector-profile", data: payload, listen: true)
        guard let wrapper = result as? [String: Any],
              let data = wrapper["data"] as? [String: Any] else {
            throw ConnectorError("Connector \(connectorId) could not be resolved")
        }
        return data
    }

    static func toProfile(_ response: [String: Any], connectorId: String) throws -> ConnectorProfile {
        guard response["status"] as? String == "successful" else {
            let error = response["error"] as? String
            throw ConnectorError(
                (error?.isEmpty == false ? error : nil) ?? "Connector \(connectorId) could not be resolved"
            )
        }

        let fields = (response["allowed_fields"] as? [[String: Any]] ?? []).map { field in
            ConnectorField(
                key: field["key"] as? String ?? "",
                label: field["label"] as? String ?? "",
                type: field["type"] as? String ?? "string",
                placeholder: field["placeholder"] as? String,
                required: (field["required"] as? NSNumber)?.boolValue,
                description: field["description"] as? String
            )
        }

        var metadata: [String: String] = [:]
        for (key, value) in response["metadata"] as? [String: Any] ?? [:] {
            metadata[key] = value as? String ?? String(describing: value)
        }

        return ConnectorProfile(
            connectorId: ArtJSON.string(response["connector_id"]) ?? connectorId,
            provider: response["provider"] as? String ?? "",
            allowedFields: fields,
            metadata: metadata
        )
    }
}
