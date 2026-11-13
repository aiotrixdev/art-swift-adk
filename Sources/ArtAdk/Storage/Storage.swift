//
//  Storage.swift
//  ArtAdk
//
//  Temporary media, scoped to a conversation thread and owned by a
//  configuration (an agent, an orchestrator, or the project by default):
//    upload  POST   {gateway}/api/{org}/datalake/v1/system-buckets/temp/objects
//            multipart: file, owner_config_id, thread_id, ttl_seconds?,
//            allowed_mime_types? → then POST /objects/{id}/access-url
//    list    GET    /objects?accessible_by=&thread_id=&page=&page_size=
//    get     GET    /objects/{id} + POST /objects/{id}/access-url
//    delete  DELETE /objects/{id}
//  `{gateway}` is Constant.BASE_URL without a trailing `/ws`.
//
//  To let an agent use an uploaded file, attach it to the run:
//    let ref = try await thread.upload(fileURL: url)
//    try await thread.run("Summarize this", fileMeta: [MediaRef(ref)])
//

import Foundation
import UniformTypeIdentifiers

// MARK: - Storage

public final class Storage {

    public init() {}

    private enum UploadBody {
        case data(Data)
        case file(URL)
    }

    // MARK: upload

    /// Uploads a local file (e.g. a `PhotosPicker` / `fileImporter` result),
    /// streaming it from disk. The file name and MIME type are taken from
    /// the URL (`options.filename` overrides the name).
    ///
    /// `options.threadId` is required. Throws `UploadError` with step
    /// `validate` when the file is empty, the thread id is missing or the
    /// ADK is not connected, and with step `upload` or `get` when the server
    /// rejects the request.
    @discardableResult
    public func upload(fileURL: URL, options: UploadOptions = UploadOptions()) async throws -> FileRef {
        let didStartScopedAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if didStartScopedAccess { fileURL.stopAccessingSecurityScopedResource() } }

        let byteCount: Int
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == false {
                throw UploadError("\(fileURL.lastPathComponent) is not a regular file", step: .validate)
            }
            if let size = values.fileSize {
                byteCount = size
            } else {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            }
        } catch let error as UploadError {
            throw error
        } catch {
            throw UploadError(
                "failed to read file at \(fileURL.lastPathComponent): \(error.localizedDescription)",
                step: .validate, underlying: error
            )
        }

        let contentType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"

        return try await performUpload(
            .file(fileURL),
            byteCount: byteCount,
            filename: fileURL.lastPathComponent,
            contentType: contentType,
            options: options
        )
    }

    /// Uploads in-memory bytes.
    ///
    /// - Parameters:
    ///   - data: the bytes to upload.
    ///   - filename: used when `options.filename` is not set, else
    ///     `upload.bin`.
    ///   - contentType: MIME type; defaults to `application/octet-stream`.
    ///   - options: upload settings; `threadId` is required.
    @discardableResult
    public func upload(
        data: Data,
        filename: String? = nil,
        contentType: String? = nil,
        options: UploadOptions = UploadOptions()
    ) async throws -> FileRef {
        try await performUpload(
            .data(data),
            byteCount: data.count,
            filename: filename,
            contentType: contentType ?? "application/octet-stream",
            options: options
        )
    }

    private func performUpload(
        _ body: UploadBody,
        byteCount: Int,
        filename: String?,
        contentType: String,
        options: UploadOptions
    ) async throws -> FileRef {
        guard byteCount > 0 else {
            throw UploadError("file is empty", step: .validate)
        }
        let credentials = try Storage.credentials("call connect() before upload()")
        let fileName = options.filename ?? filename ?? "upload.bin"
        let configId = options.configId ?? credentials.projectKey
        let threadId = try Storage.requireThreadId(options.threadId)

        var fields: [(String, String)] = [
            ("owner_config_id", configId),
            ("thread_id", threadId),
        ]
        if let ttl = options.ttlSeconds { fields.append(("ttl_seconds", String(ttl))) }
        if let mimeTypes = options.allowedMimeTypes, !mimeTypes.isEmpty {
            let json = (try? JSONSerialization.data(withJSONObject: mimeTypes, options: [.withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            fields.append(("allowed_mime_types", json))
        }

        options.progress?(0)
        let object = try await sendUpload(
            body, fields: fields, filename: fileName, contentType: contentType,
            baseUrl: Storage.baseUrl(credentials), options: options
        )
        guard let objectId = ArtJSON.string(object["id"]) else {
            throw UploadError("Datalake upload did not return an object ID", step: .upload)
        }
        options.progress?(1)

        let access = try await datalakeCall(
            .get, method: "POST",
            path: "/objects/\(ArtEncoding.uriComponent(objectId))/access-url",
            query: Storage.accessQuery(configId, threadId),
            timeoutMs: options.timeoutMs
        )
        let storedName = object["name"] as? String ?? ""
        let storedType = object["content_type"] as? String ?? ""
        return FileRef(
            fileId: objectId,
            name: storedName.isEmpty ? fileName : storedName,
            readUrl: (access as? [String: Any])?["read_url"] as? String ?? "",
            size: ArtJSON.int(object["size_bytes"]) ?? byteCount,
            contentType: storedType.isEmpty ? contentType : storedType
        )
    }

    // MARK: listFiles

    /// Lists the files `options.configId` (default: the project key) can
    /// access in `options.threadId` (required). Files carry no `readUrl`.
    public func listFiles(options: ListOptions = ListOptions()) async throws -> StorageFileList {
        let configId = try options.configId ?? Storage.credentials("call connect() before using storage").projectKey
        let threadId = try Storage.requireThreadId(options.threadId)

        var query = Storage.accessQuery(configId, threadId)
        if let page = options.page { query.append(("page", String(page))) }
        if let limit = options.limit { query.append(("page_size", String(limit))) }
        let response = try await datalakeCall(.list, method: "GET", path: "/objects", query: query, timeoutMs: nil)

        let json = response as? [String: Any]
        let files = (json?["data"] as? [[String: Any]] ?? []).map { toStorageFile($0) }
        let total = ArtJSON.int((json?["meta"] as? [String: Any])?["total"]) ?? files.count
        return StorageFileList(files: files, total: total)
    }

    // MARK: getFile

    /// Fetches the metadata and a read URL of the file `fileId` in
    /// `threadId`.
    public func getFile(fileId: String, threadId: String, timeoutMs: Int? = nil) async throws -> StorageFile {
        let configId = try Storage.credentials("call connect() before using storage").projectKey
        let thread = try Storage.requireThreadId(threadId)
        let query = Storage.accessQuery(configId, thread)
        let path = "/objects/\(ArtEncoding.uriComponent(fileId))"

        let object = try await datalakeCall(.get, method: "GET", path: path, query: query, timeoutMs: timeoutMs)
        let access = try await datalakeCall(
            .get, method: "POST", path: "\(path)/access-url", query: query, timeoutMs: timeoutMs
        )
        return toStorageFile(
            Storage.dataObject(object),
            readUrl: (access as? [String: Any])?["read_url"] as? String
        )
    }

    // MARK: deleteFile

    /// Deletes the file `fileId`. `hard` is ignored: files are always
    /// removed.
    public func deleteFile(fileId: String, hard: Bool = false, timeoutMs: Int? = nil) async throws {
        _ = try await datalakeCall(
            .delete, method: "DELETE",
            path: "/objects/\(ArtEncoding.uriComponent(fileId))",
            query: [], timeoutMs: timeoutMs
        )
    }

    // MARK: - Private helpers

    private func toStorageFile(_ object: [String: Any], readUrl: String? = nil) -> StorageFile {
        StorageFile(
            fileId: ArtJSON.string(object["id"]) ?? "",
            name: object["name"] as? String ?? "",
            configType: "media",
            configId: object["owner_config_id"] as? String ?? "",
            size: ArtJSON.int(object["size_bytes"]) ?? 0,
            contentType: object["content_type"] as? String ?? "",
            status: "active",
            createdAt: object["created_at"] as? String ?? "",
            expiresAt: object["expires_at"] as? String,
            readUrl: readUrl
        )
    }

    private static func credentials(_ message: String) throws -> AuthenticationConfig {
        do {
            return try Auth.getInstance().getCredentials()
        } catch {
            throw UploadError(message, step: .validate)
        }
    }

    private static func requireThreadId(_ threadId: String?) throws -> String {
        let value = threadId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw UploadError("threadId is required for temporary media", step: .validate)
        }
        return value
    }

    private static func accessQuery(_ configId: String, _ threadId: String) -> [(String, String)] {
        [("accessible_by", configId), ("thread_id", threadId)]
    }

    private static func baseUrl(_ credentials: AuthenticationConfig) -> String {
        "\(ArtGateway.restBase)/api/\(ArtEncoding.uriComponent(credentials.orgTitle))/datalake/v1/system-buckets/temp"
    }

    private static func dataObject(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    /// Calls the temporary-media bucket. Returns the response's `data`, or
    /// `{data, meta}` for `.list`.
    private func datalakeCall(
        _ step: UploadStep,
        method: String,
        path: String,
        query: [(String, String)],
        timeoutMs: Int?
    ) async throws -> Any? {
        let credentials = try Storage.credentials("call connect() before using storage")
        let endpoint = query.isEmpty ? path : "\(path)?\(ArtEncoding.formQuery(query))"
        do {
            let json = try await httpCall(endpoint, options: CallApiProps(
                method: method, baseUrl: Storage.baseUrl(credentials), timeoutMs: timeoutMs
            ))
            let map = json as? [String: Any] ?? [:]
            if step == .list {
                return ["data": map["data"] ?? [Any](), "meta": map["meta"] ?? [String: Any]()]
            }
            return map["data"]
        } catch {
            throw Storage.uploadError(step, error)
        }
    }

    private static func uploadError(_ step: UploadStep, _ error: Error) -> Error {
        switch error {
        case let error as UploadError:
            return error
        case let error as HTTPCallError:
            // Keep the status: a 403 means the tenant role lacks storage
            // permission.
            return UploadError(
                "Datalake \(step.rawValue) failed: \(error.message)",
                step: step, status: error.status, underlying: error
            )
        default:
            return UploadError(
                "Datalake \(step.rawValue) failed: \(error.localizedDescription)",
                step: step, underlying: error
            )
        }
    }

    /// POSTs the multipart upload with its own session so progress can be
    /// reported; file bodies are staged in a temporary file and streamed.
    private func sendUpload(
        _ body: UploadBody,
        fields: [(String, String)],
        filename: String,
        contentType: String,
        baseUrl: String,
        options: UploadOptions
    ) async throws -> [String: Any] {
        let multipart = MultipartBody()
        var request: URLRequest
        do {
            request = try await artAuthorizedRequest("/objects", options: CallApiProps(
                method: "POST", baseUrl: baseUrl, timeoutMs: options.timeoutMs ?? 60_000
            ))
        } catch {
            throw Storage.uploadError(.upload, error)
        }
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")

        var stagedFile: URL?
        defer { if let stagedFile { try? FileManager.default.removeItem(at: stagedFile) } }

        let delegate = UploadProgressDelegate(progress: options.progress)
        let session = URLSession(configuration: ArtHTTP.uploadConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            switch body {
            case .data(let bytes):
                let file = FormDataFile(field: "file", data: bytes, filename: filename, contentType: contentType)
                (data, response) = try await session.upload(
                    for: request, from: multipart.encode(fields: fields, files: [file]), delegate: delegate
                )
            case .file(let fileURL):
                let staged = FileManager.default.temporaryDirectory
                    .appendingPathComponent("art-upload-\(UUID().uuidString)")
                stagedFile = staged
                try multipart.write(
                    fields: fields, field: "file", filename: filename,
                    contentType: contentType, source: fileURL, to: staged
                )
                (data, response) = try await session.upload(for: request, fromFile: staged, delegate: delegate)
            }
        } catch let error as URLError where error.code == .timedOut {
            throw UploadError("Datalake upload timed out", step: .upload, underlying: error)
        } catch {
            throw Storage.uploadError(.upload, error)
        }

        do {
            let json = try artDecodeResponse(data, response, endpoint: "/objects")
            return Storage.dataObject((json as? [String: Any])?["data"])
        } catch {
            throw Storage.uploadError(.upload, error)
        }
    }
}

/// Reports upload progress while the body is sent. `1` is left for the
/// moment the server has stored the file.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let progress: ((Double) -> Void)?

    init(progress: ((Double) -> Void)?) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0, totalBytesSent < totalBytesExpectedToSend else { return }
        progress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
