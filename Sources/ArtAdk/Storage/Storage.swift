//
//  Storage.swift
//  ArtAdk
//
//  upload(file)
//    1. POST {gateway}/api/{org}/storage/upload/signed-url   (authenticated)
//       { config_type, config_id, file_name, file_size, content_type,
//         scopes, ttl_seconds? } → { file_id, upload_url }
//    2. PUT upload_url  (x-ms-blob-type: BlockBlob; no ART auth — SAS URL)
//    3. POST {gateway}/api/{org}/storage/upload/confirm/{file_id}
//       → { read_url, file }
//  `{gateway}` is Constant.BASE_URL without a trailing `/ws`.
//
//  To let an agent use an uploaded file, attach it to the run:
//    let ref = try await agent.upload(fileURL: url)
//    try await thread.run("Summarize this", fileMeta: [FileMeta(ref)])
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
    ///   - options: upload settings such as the owner, scopes and progress
    ///     callback.
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

        let auth: Auth
        do {
            auth = try Auth.getInstance()
        } catch {
            throw UploadError("call connect() before upload()", step: .validate)
        }

        let fileName = options.filename ?? filename ?? "upload.bin"
        let configId = options.configId ?? auth.getCredentials().projectKey

        var requestBody: [String: Any] = [
            "config_type": (options.configType ?? .media).rawValue,
            "config_id": configId,
            "file_name": fileName,
            "file_size": byteCount,
            "content_type": contentType,
            "scopes": options.scopes,
        ]
        if let ttl = options.ttlSeconds { requestBody["ttl_seconds"] = ttl }

        let initResponse = try await storageCall(
            .signedURL, method: "POST", path: "/upload/signed-url",
            body: requestBody, timeoutMs: options.timeoutMs
        )

        guard
            let fileId = ArtJSON.string(initResponse["file_id"]),
            let uploadURLString = initResponse["upload_url"] as? String,
            let uploadURL = URL(string: uploadURLString)
        else {
            throw UploadError("signed-url missing file_id/upload_url", step: .signedURL)
        }

        try await putToStorage(uploadURL, body: body, contentType: contentType, options: options)

        let done = try await storageCall(
            .confirm, method: "POST", path: "/upload/confirm/\(ArtEncoding.uriComponent(fileId))",
            timeoutMs: options.timeoutMs
        )

        let file = done["file"] as? [String: Any]
        return FileRef(
            fileId: fileId,
            name: fileName,
            readUrl: done["read_url"] as? String ?? "",
            size: ArtJSON.int(file?["file_size"]) ?? byteCount,
            contentType: contentType
        )
    }

    // MARK: listFiles

    /// Lists stored files, optionally filtered by storage group.
    public func listFiles(options: ListOptions = ListOptions()) async throws -> StorageFileList {
        // Fixed parameter order; empty values are left out.
        var query: [(String, String)] = []
        if let configType = options.configType, !configType.rawValue.isEmpty {
            query.append(("config_type", configType.rawValue))
        }
        if let configId = options.configId, !configId.isEmpty {
            query.append(("config_id", configId))
        }
        if let page = options.page { query.append(("page", String(page))) }
        if let limit = options.limit { query.append(("limit", String(limit))) }
        let path = "/files" + (query.isEmpty ? "" : "?" + ArtEncoding.formQuery(query))

        let data = try await storageCall(.list, method: "GET", path: path, timeoutMs: nil)

        let files = (data["files"] as? [[String: Any]] ?? []).map { toStorageFile($0) }
        return StorageFileList(files: files, total: ArtJSON.int(data["total"]) ?? 0)
    }

    // MARK: getFile

    /// Fetches one file's metadata, including a signed `readUrl`.
    public func getFile(fileId: String, timeoutMs: Int? = nil) async throws -> StorageFile {
        let data = try await storageCall(
            .get, method: "GET", path: "/file/\(ArtEncoding.uriComponent(fileId))",
            timeoutMs: timeoutMs
        )
        return toStorageFile(data["file"] as? [String: Any], readUrl: data["read_url"] as? String)
    }

    // MARK: deleteFile

    /// Deletes a file; `hard: true` removes it permanently.
    public func deleteFile(fileId: String, hard: Bool = false, timeoutMs: Int? = nil) async throws {
        let path = "/file/\(ArtEncoding.uriComponent(fileId))\(hard ? "/hard" : "")"
        _ = try await storageCall(.delete, method: "DELETE", path: path, timeoutMs: timeoutMs)
    }

    // MARK: - Private helpers

    private func toStorageFile(_ f: [String: Any]?, readUrl: String? = nil) -> StorageFile {
        StorageFile(
            fileId: ArtJSON.string(f?["id"]) ?? "",
            name: f?["original_name"] as? String ?? "",
            configType: f?["config_type"] as? String ?? "",
            configId: f?["config_id"] as? String ?? "",
            size: ArtJSON.int(f?["file_size"]) ?? 0,
            contentType: f?["content_type"] as? String ?? "",
            status: f?["status"] as? String ?? "",
            createdAt: f?["created_at"] as? String ?? "",
            expiresAt: f?["expires_at"] as? String,
            readUrl: readUrl ?? (f?["read_url"] as? String)
        )
    }

    /// Authenticated call to the storage API; returns the `data` object.
    private func storageCall(
        _ step: UploadStep,
        method: String,
        path: String,
        body: [String: Any]? = nil,
        timeoutMs: Int?
    ) async throws -> [String: Any] {
        let orgTitle: String
        do {
            orgTitle = try Auth.getInstance().getCredentials().orgTitle
        } catch {
            throw UploadError("call connect() before using storage", step: .validate)
        }

        let baseUrl = "\(ArtGateway.restBase)/api/\(ArtEncoding.uriComponent(orgTitle))/storage"

        do {
            let json = try await httpCall(path, options: CallApiProps(
                method: method, payload: body, baseUrl: baseUrl, timeoutMs: timeoutMs
            ))
            return (json as? [String: Any])?["data"] as? [String: Any] ?? [:]
        } catch let error as HTTPCallError {
            // Keep the status: a 403 on signed-url means the tenant role
            // lacks storage permission.
            throw UploadError(
                "storage \(step.rawValue) failed: \(error.errorDescription ?? error.message)",
                step: step, status: error.status, underlying: error
            )
        } catch let error as UploadError {
            throw error
        } catch {
            throw UploadError(
                "storage \(step.rawValue) failed: \(error.localizedDescription)",
                step: step, underlying: error
            )
        }
    }

    /// PUT the bytes to the signed blob-storage URL, reporting progress via
    /// `options.progress`. File bodies stream from disk.
    private func putToStorage(
        _ url: URL,
        body: UploadBody,
        contentType: String,
        options: UploadOptions
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = TimeInterval(options.timeoutMs ?? 60_000) / 1000

        options.progress?(0)

        let delegate = UploadProgressDelegate(progress: options.progress)
        let session = URLSession(configuration: ArtHTTP.uploadConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let response: URLResponse
            switch body {
            case .data(let data):
                (_, response) = try await session.upload(for: request, from: data, delegate: delegate)
            case .file(let fileURL):
                (_, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode
                throw UploadError(
                    "storage PUT failed (\(status.map(String.init) ?? "no response"))",
                    step: .put, status: status
                )
            }
            options.progress?(1)
        } catch let error as UploadError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw UploadError("storage PUT timed out", step: .put, underlying: error)
        } catch {
            throw UploadError("storage PUT failed (network/timeout)", step: .put, underlying: error)
        }
    }
}

/// Reports fractional upload progress (0...1) during the PUT-to-blob step.
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
        guard totalBytesExpectedToSend > 0 else { return }
        progress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
