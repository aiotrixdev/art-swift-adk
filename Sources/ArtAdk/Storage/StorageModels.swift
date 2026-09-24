//
//  StorageModels.swift
//  ArtAdk
//
//  Created by SSA on 20/07/26.
//
//  Storage models: `ConfigType`, `FileRef`, `StorageFile` and the
//  `file_meta` entry shape.
//

import Foundation

// MARK: - ConfigType

/// Storage group type (`config_type`), e.g. `media` or `knowledge_base`.
/// Extensible — any server value can be expressed as a string literal.
public struct ConfigType: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let media = ConfigType(rawValue: "media")
    public static let knowledgeBase = ConfigType(rawValue: "knowledge_base")
}

// MARK: - FileRef

/// Result of a successful upload.
public struct FileRef: Hashable, Codable, Sendable {
    public let fileId: String
    public let name: String
    public let readUrl: String
    public let size: Int
    public let contentType: String
    public init(fileId: String, name: String, readUrl: String, size: Int, contentType: String) {
        self.fileId = fileId
        self.name = name
        self.readUrl = readUrl
        self.size = size
        self.contentType = contentType
    }
}

// MARK: - StorageFile

/// A stored file as returned by `listFiles` / `getFile`.
public struct StorageFile: Hashable, Codable, Sendable, Identifiable {
    public var id: String { fileId }

    public let fileId: String
    public let name: String
    public let configType: String
    public let configId: String
    public let size: Int
    public let contentType: String
    public let status: String
    public let createdAt: String
    public let expiresAt: String?
    /// Present from `getFile`, absent from `listFiles`.
    public let readUrl: String?
    public init(
        fileId: String,
        name: String,
        configType: String,
        configId: String,
        size: Int,
        contentType: String,
        status: String,
        createdAt: String,
        expiresAt: String?,
        readUrl: String?
    ) {
        self.fileId = fileId
        self.name = name
        self.configType = configType
        self.configId = configId
        self.size = size
        self.contentType = contentType
        self.status = status
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.readUrl = readUrl
    }
}

// MARK: - StorageFileList

/// One page of `listFiles` results.
public struct StorageFileList: Hashable, Sendable {
    public let files: [StorageFile]
    public let total: Int

    public init(files: [StorageFile], total: Int) {
        self.files = files
        self.total = total
    }
}

// MARK: - FileMeta

/// An uploaded file attached to a message, sent as an entry of the frame's
/// top-level `file_meta` array (`{ "id": ..., "scope": [...] }`).
///
/// `scope` lists the config ids (e.g. agent ids) allowed to read the file
/// for this message; empty = owner-only.
public struct FileMeta: Hashable, Codable, Sendable {
    public var id: String
    public var scope: [String]

    public init(id: String, scope: [String] = []) {
        self.id = id
        self.scope = scope
    }

    /// Attaches an uploaded file.
    public init(_ file: FileRef, scope: [String] = []) {
        self.init(id: file.fileId, scope: scope)
    }

    var jsonObject: [String: Any] { ["id": id, "scope": scope] }
}
