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
    /// Configuration for the per-upload sessions used by storage PUTs
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
///    caller headers, and `Content-Type: application/json` when a payload
///    is sent
/// 4. Non-2xx → `HTTPCallError`; 204 / empty body → `nil`; otherwise the
///    decoded JSON.
///
/// Throws `ARTError.forbidden` when called before `connect()` created the
/// auth singleton.
@discardableResult
func httpCall(_ endpoint: String, options: CallApiProps = CallApiProps()) async throws -> Any? {
    // 1) fresh token
    let auth = try Auth.getInstance()
    let authData = try await auth.authenticate()
    let credentials = auth.getCredentials()

    // 2) URL (+ optional query). baseUrl overrides the default host.
    var urlString = (options.baseUrl ?? Constant.BASE_URL) + endpoint
    if let queryParams = options.queryParams {
        urlString += "?" + ArtEncoding.formQuery(queryParams)
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
    if let payload = options.payload {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ArtJSON.stringify(payload).data(using: .utf8)
    }

    // 5) optional timeout (cancellation follows the calling Task)
    if let timeoutMs = options.timeoutMs {
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000
    }

    let (data, response) = try await ArtHTTP.session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw ARTError.serverError("No HTTP response for \(endpoint)")
    }

    // 6) error handling
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

    // 7) 204 No Content
    if http.statusCode == 204 || data.isEmpty { return nil }

    // 8) parse and resolve
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}
