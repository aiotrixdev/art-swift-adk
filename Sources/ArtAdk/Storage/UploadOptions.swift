//
//  UploadOptions.swift
//  ArtAdk
//
//  Created by SSA on 20/07/26.
//
//  Request options and errors for the storage API: `UploadOptions`,
//  `ListOptions` and `UploadError`.
//

import Foundation

// MARK: - UploadOptions

/// Options for `upload(...)`.
///
/// Uploads are temporary media scoped to a conversation thread, so
/// `threadId` is required; the thread-level `upload` helpers set it.
/// Scoped entry points (`Agent`, `AgentThread`, `Orchestrator`,
/// `OrchestratorThread`, `Subscription`) always set `configId` to their
/// channel's configuration. To cancel an upload, cancel the calling `Task`.
public struct UploadOptions {
    /// File name sent to storage. Defaults to the file URL's last path
    /// component (or the `filename` argument), else `upload.bin`.
    public var filename: String?
    /// Storage file category. Only `.media` is supported.
    public var configType: ConfigType?
    /// Configuration that owns the file. Defaults to the project key for
    /// `Adk.upload`.
    public var configId: String?
    /// Thread the file belongs to. Required.
    public var threadId: String?
    /// No longer used: access follows the owning configuration and thread.
    @available(*, deprecated, message: "Uploads are scoped to their thread; scopes are ignored.")
    public var scopes: [String] = []
    /// Time-to-live for the uploaded file, in seconds.
    public var ttlSeconds: Int?
    /// MIME types the server should accept for this upload.
    public var allowedMimeTypes: [String]?
    /// Request timeout in milliseconds (the upload defaults to 60 000).
    public var timeoutMs: Int?
    /// Upload progress from 0 to 1: `0` when the upload starts, fractions
    /// while the bytes are sent, and `1` once the server has stored the
    /// file. Called on a background thread.
    public var progress: ((Double) -> Void)?

    public init(
        filename: String? = nil,
        configType: ConfigType? = nil,
        configId: String? = nil,
        threadId: String? = nil,
        ttlSeconds: Int? = nil,
        allowedMimeTypes: [String]? = nil,
        timeoutMs: Int? = nil,
        progress: ((Double) -> Void)? = nil
    ) {
        self.filename = filename
        self.configType = configType
        self.configId = configId
        self.threadId = threadId
        self.ttlSeconds = ttlSeconds
        self.allowedMimeTypes = allowedMimeTypes
        self.timeoutMs = timeoutMs
        self.progress = progress
    }

    @available(*, deprecated, message: "Uploads are scoped to their thread; scopes are ignored. Pass threadId instead.")
    public init(
        filename: String? = nil,
        configType: ConfigType? = nil,
        configId: String? = nil,
        scopes: [String],
        ttlSeconds: Int? = nil,
        timeoutMs: Int? = nil,
        progress: ((Double) -> Void)? = nil
    ) {
        self.init(
            filename: filename, configType: configType, configId: configId,
            ttlSeconds: ttlSeconds, timeoutMs: timeoutMs, progress: progress
        )
        self.scopes = scopes
    }
}

// MARK: - ListOptions

/// Filters for `listFiles(...)`.
///
/// Files are listed per thread, so `threadId` is required; the
/// thread-level `listFiles` helpers set it.
public struct ListOptions {
    /// Storage file category. Only `.media` is supported.
    public var configType: ConfigType?
    /// List the files this configuration can access. Defaults to the
    /// project key; scoped entry points set it for you.
    public var configId: String?
    /// Thread whose files are listed. Required.
    public var threadId: String?
    /// Page number (1-based).
    public var page: Int?
    /// Maximum files per page.
    public var limit: Int?
    public init(
        configType: ConfigType? = nil,
        configId: String? = nil,
        threadId: String? = nil,
        page: Int? = nil,
        limit: Int? = nil
    ) {
        self.configType = configType
        self.configId = configId
        self.threadId = threadId
        self.page = page
        self.limit = limit
    }
}

// MARK: - UploadError

/// Storage step that failed.
public enum UploadStep: String, Sendable {
    case validate
    case upload
    case list
    case get
    case delete
    @available(*, deprecated, message: "No longer reported: an upload is a single request (`.upload`).")
    case signedURL = "signed-url"
    @available(*, deprecated, message: "No longer reported: an upload is a single request (`.upload`).")
    case put
    @available(*, deprecated, message: "No longer reported: an upload is a single request (`.upload`).")
    case confirm
}

/// Error thrown by the storage API.
///
/// `status` is kept for every step, so a `403` — the tenant role lacks
/// storage permission — can be told apart from network failures.
public struct UploadError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public let step: UploadStep
    /// HTTP status, when the failure was an HTTP response.
    public let status: Int?
    public let underlying: Error?
    public init(_ message: String, step: UploadStep, status: Int? = nil, underlying: Error? = nil) {
        self.message = message
        self.step = step
        self.status = status
        self.underlying = underlying
    }

    /// `step` as its wire string (e.g. `"upload"`).
    public var stage: String { step.rawValue }
    /// Alias of `status`.
    public var statusCode: Int? { status }

    public var errorDescription: String? { message }
    public var description: String { "UploadError(\(step.rawValue)): \(message)" }
}
