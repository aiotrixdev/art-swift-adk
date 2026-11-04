// Sources/ArtAdk/WebSocket/HTTPCall.swift
//
// Shared authenticated REST helper, used by `Adk.call`, storage,
// `updateProfile` and plugins so every request gets a fresh token and the
// same ART headers.

import Foundation

// MARK: - Transport seam

/// URLSession seam. Tests replace these with sessions whose configuration
/// registers a stub `URLProtocol`.
enum ArtHTTP {
    /// Session for auth and REST calls.
    static var session: URLSession = .shared
    /// Configuration for the per-upload sessions used by storage uploads
    /// (each upload needs its own delegate for progress).
    static var uploadConfiguration: URLSessionConfiguration = .ephemeral
}

// MARK: - Gateway URLs

enum ArtGateway {
    /// `Constant.BASE_URL` with a trailing `/ws` removed — where the
    /// gateway's REST APIs (`/api/<org>/...`) live.
    static var restBase: String {
        var base = Constant.BASE_URL
        if base.hasSuffix("/ws") { base.removeLast(3) }
        return base
    }

    /// Origin (scheme://host[:port]) of `Constant.BASE_URL`; returned by
    /// the plugin context's `baseUrl()`.
    static var origin: String {
        guard let components = URLComponents(string: Constant.BASE_URL),
              let scheme = components.scheme,
              let host = components.host else { return Constant.BASE_URL }
        if let port = components.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }
}

// MARK: - Errors

/// Non-2xx response from an ART REST endpoint.
public struct HTTPCallError: Error, LocalizedError, CustomStringConvertible {
    /// The endpoint path that was called.
    public let endpoint: String
    /// HTTP status code.
    public let status: Int
    /// Server `message`, else the JSON error body, else the status text.
    public let message: String
    /// Decoded JSON error body, when there was one.
    public let body: Any?

    public init(endpoint: String, status: Int, message: String, body: Any? = nil) {
        self.endpoint = endpoint
        self.status = status
        self.message = message
        self.body = body
    }

    public var errorDescription: String? { "API \(endpoint) failed: \(message)" }
    public var description: String { errorDescription ?? message }
}

// MARK: - httpCall

/// Calls an ART REST endpoint with a fresh access token.
///
/// 1. `Auth.authenticate()` (refreshes when needed)
/// 2. `baseUrl ?? Constant.BASE_URL` + `endpoint` (+ form-encoded query)
/// 3. `Authorization`, `Accept`, `X-Org`, `Environment`, `ProjectKey`,
///    caller headers, and the body's `Content-Type`: `multipart/form-data`
///    for a `FormDataPayload`, else `application/json`
/// 4. Non-2xx → `HTTPCallError`; 204 / empty body → `nil`; otherwise the
///    decoded JSON.
///
/// Throws `ARTError.forbidden` when called before `connect()` created the
/// auth singleton.
@discardableResult
func httpCall(_ endpoint: String, options: CallApiProps = CallApiProps()) async throws -> Any? {
    let request = try await artAuthorizedRequest(endpoint, options: options)
    let (data, response) = try await ArtHTTP.session.data(for: request)
    return try artDecodeResponse(data, response, endpoint: endpoint)
}

/// Builds the request `httpCall` sends: URL, ART headers, body and timeout.
func artAuthorizedRequest(_ endpoint: String, options: CallApiProps) async throws -> URLRequest {
    // 1) fresh token
    let auth = try Auth.getInstance()
    let authData = try await auth.authenticate()
    let credentials = auth.getCredentials()

    // 2) URL (+ optional query). baseUrl overrides the default host.
    var urlString = (options.baseUrl ?? Constant.BASE_URL) + endpoint
    if let queryParams = options.queryParams, !queryParams.isEmpty {
        urlString += (urlString.contains("?") ? "&" : "?") + ArtEncoding.formQuery(queryParams)
    }
    guard let url = URL(string: urlString) else {
        throw ARTError.invalidPath("Malformed API URL: \(urlString)")
    }

    // 3) headers
    var request = URLRequest(url: url)
    request.httpMethod = options.method.uppercased()
    request.setValue("Bearer \(authData.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(credentials.orgTitle, forHTTPHeaderField: "X-Org")
    request.setValue(credentials.environment, forHTTPHeaderField: "Environment")
    request.setValue(credentials.projectKey, forHTTPHeaderField: "ProjectKey")
    options.headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }

    // 4) body
    if let form = options.payload as? FormDataPayload {
        let body = MultipartBody()
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.encode(
            fields: form.fields.keys.sorted().map { ($0, form.fields[$0] ?? "") },
            files: form.files
        )
    } else if let payload = options.payload {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ArtJSON.stringify(payload).data(using: .utf8)
    }

    // 5) optional timeout (cancellation follows the calling Task)
    if let timeoutMs = options.timeoutMs {
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000
    }
    return request
}

/// Decodes a REST response: non-2xx → `HTTPCallError`; 204 / empty body →
/// `nil`; otherwise the decoded JSON.
func artDecodeResponse(_ data: Data, _ response: URLResponse, endpoint: String) throws -> Any? {
    guard let http = response as? HTTPURLResponse else {
        throw ARTError.serverError("No HTTP response for \(endpoint)")
    }

    guard (200..<300).contains(http.statusCode) else {
        var message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        var body: Any?
        if !data.isEmpty, let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            body = decoded
            if let serverMessage = (decoded as? [String: Any])?["message"] as? String, !serverMessage.isEmpty {
                message = serverMessage
            } else if let text = try? ArtJSON.stringify(decoded) {
                message = text
            }
        }
        throw HTTPCallError(endpoint: endpoint, status: http.statusCode, message: message, body: body)
    }

    if http.statusCode == 204 || data.isEmpty { return nil }
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

// MARK: - Bounded requests

/// `ArtHTTP.session.data(for:)`, abandoned after `timeoutMs` milliseconds:
/// the request is cancelled and the error from `timeoutError` is thrown.
func artData(
    for request: URLRequest,
    timeoutMs: Int,
    timeoutError: @escaping @Sendable () -> Error
) async throws -> (Data, URLResponse) {
    var request = request
    request.timeoutInterval = max(TimeInterval(timeoutMs) / 1000, 0.001)
    let session = ArtHTTP.session
    return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
        group.addTask {
            do {
                return try await session.data(for: request)
            } catch let error as URLError where error.code == .timedOut {
                throw timeoutError()
            }
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(timeoutMs, 0)) * 1_000_000)
            throw timeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}

// MARK: - Multipart bodies

/// Builds `multipart/form-data` bodies: text fields first, then files.
struct MultipartBody {
    let boundary = "ArtAdkFormBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// The whole body in memory.
    func encode(fields: [(String, String)], files: [FormDataFile]) -> Data {
        var body = encodeFields(fields)
        for file in files {
            body.append(fileHeader(field: file.field, filename: file.filename, contentType: file.contentType))
            body.append(file.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(closing)
        return body
    }

    /// Writes a body with one file part, copied from `source` in chunks,
    /// to `destination`, so large files are never held in memory.
    func write(
        fields: [(String, String)],
        field: String,
        filename: String,
        contentType: String,
        source: URL,
        to destination: URL
    ) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        var head = encodeFields(fields)
        head.append(fileHeader(field: field, filename: filename, contentType: contentType))
        try output.write(contentsOf: head)
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        var tail = Data("\r\n".utf8)
        tail.append(closing)
        try output.write(contentsOf: tail)
    }

    private var closing: Data { Data("--\(boundary)--\r\n".utf8) }

    private func encodeFields(_ fields: [(String, String)]) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(Data((
                "--\(boundary)\r\n" +
                "Content-Disposition: form-data; name=\"\(MultipartBody.quoted(name))\"\r\n\r\n" +
                "\(value)\r\n"
            ).utf8))
        }
        return body
    }

    private func fileHeader(field: String, filename: String, contentType: String?) -> Data {
        Data((
            "--\(boundary)\r\n" +
            "Content-Disposition: form-data; name=\"\(MultipartBody.quoted(field))\"; " +
            "filename=\"\(MultipartBody.quoted(filename))\"\r\n" +
            "Content-Type: \(contentType ?? "application/octet-stream")\r\n\r\n"
        ).utf8)
    }

    /// Escapes a quoted header parameter the way browsers do.
    private static func quoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}
