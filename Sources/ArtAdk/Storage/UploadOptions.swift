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
/// Scoped entry points (`Agent`, `AgentThread`, `Orchestrator`,
/// `OrchestratorThread`, `Subscription`) always override `configId` with
/// their own id. To cancel an upload, cancel the calling `Task`.
public struct UploadOptions {
    /// File name sent to storage. Defaults to the file URL's last path
    /// component (or the `filename` argument), else `upload.bin`.
    public var filename: String?
    /// Storage group type. Defaults to `.media`.
    public var configType: ConfigType?
    /// Owning config id. Defaults to the project key for `Adk.upload`.
    public var configId: String?
    /// Config ids granted access to the file; empty = owner-only.
    public var scopes: [String]
    /// Optional expiry in seconds.
    public var ttlSeconds: Int?
    /// Per-request timeout in milliseconds (the PUT defaults to 60 000).
    public var timeoutMs: Int?
    /// Upload progress 0...1 for the PUT step. Called on
    /// a background thread.
    public var progress: ((Double) -> Void)?

    public init(
        filename: String? = nil,
        configType: ConfigType? = nil,
        configId: String? = nil,
        scopes: [String] = [],
        ttlSeconds: Int? = nil,
        timeoutMs: Int? = nil,
        progress: ((Double) -> Void)? = nil
    ) {
        self.filename = filename
        self.configType = configType
        self.configId = configId
        self.scopes = scopes
        self.ttlSeconds = ttlSeconds
        self.timeoutMs = timeoutMs
        self.progress = progress
    }
}

// MARK: - ListOptions

/// Filters for `listFiles(...)`.
public struct ListOptions {
    public var configType: ConfigType?
    /// Storage group to list; scoped entry points set it for you.
    public var configId: String?
    public var page: Int?
    public var limit: Int?
    public init(
        configType: ConfigType? = nil,
        configId: String? = nil,
        page: Int? = nil,
        limit: Int? = nil
    ) {
        self.configType = configType
        self.configId = configId
        self.page = page
        self.limit = limit
    }
}

// MARK: - UploadError

/// Storage step that failed.
public enum UploadStep: String, Sendable {
    case validate
    case signedURL = "signed-url"
    case put
    case confirm
    case list
    case get
    case delete
}

/// Error thrown by the storage API.
///
/// `status` is kept for every step (not just `put`),
/// so a `403` on `signed-url` — the tenant role lacks storage permission —
/// can be told apart from network failures.
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

    /// `step` as its wire string (e.g. `"signed-url"`).
    public var stage: String { step.rawValue }
    /// Alias of `status`.
    public var statusCode: Int? { status }

    public var errorDescription: String? { message }
    public var description: String { "UploadError(\(step.rawValue)): \(message)" }
}
