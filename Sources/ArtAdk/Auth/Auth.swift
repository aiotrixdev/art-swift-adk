import Foundation

// MARK: - AuthHttpError
/// An authentication request that the ART server rejected with an HTTP
/// error.
///
/// Thrown when getting or renewing a token fails, and when the server
/// refuses to renew a live connection's authorisation.
public struct AuthHttpError: Error, LocalizedError, CustomStringConvertible {
    /// Server `message`, else the HTTP status text.
    public let message: String
    /// HTTP status code returned by the server.
    public let status: Int
    /// Decoded response body, when the server sent JSON.
    public let body: Any?

    public init(_ message: String, status: Int, body: Any? = nil) {
        self.message = message
        self.status = status
        self.body = body
    }

    /// Whether the credentials themselves were rejected (HTTP 401 or 403).
    /// Retrying with the same credentials cannot succeed, so the SDK stops
    /// reconnecting when it sees one of these.
    public var isTerminal: Bool { status == 401 || status == 403 }

    public var errorDescription: String? { message }
    public var description: String { "authenticationFailed (\(status)): \(message)" }
}

/// Whether `error` is an `AuthHttpError` for rejected credentials (HTTP 401
/// or 403).
public func isTerminalAuthError(_ error: Error?) -> Bool {
    (error as? AuthHttpError)?.isTerminal == true
}

/// Token management for the ART gateway.
///
/// - `authenticate()` is single-flight: concurrent callers (socket,
///   long-poll, REST, storage) share one in-flight token request, so a
///   refresh token is never rotated twice in parallel.
/// - Access tokens are renewed 30 s **before** `exp`.
/// - A complete client ID and secret pair uses the client-credentials
///   grant: tokens are renewed by authenticating again, never with a
///   refresh token. Without a client secret, `accessToken` is exchanged and
///   renewed with the refresh token.
public final class Auth {
    // MARK: - Singleton
    private static var _instance: Auth?
    private static let lock = NSLock()

    /// Returns the process-wide `Auth` instance.
    ///
    /// `credentials` is required on the very first call. On later calls it
    /// replaces the stored credentials when it names the same identity
    /// (organisation, environment, project and client ID), and replaces the
    /// whole instance, dropping its tokens, when it names another one.
    /// Throws `ARTError.forbidden` when called for the first time without
    /// credentials.
    public static func getInstance(credentials: AuthenticationConfig? = nil) throws -> Auth {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _instance, let credentials {
            if sameIdentity(existing.getCredentials(), credentials) {
                existing.replaceCredentials(credentials)
            } else {
                _instance = Auth(credentials: credentials)
            }
        }
        if let existing = _instance {
            return existing
        }
        guard let creds = credentials else {
            throw ARTError.forbidden("Auth not initialised – provide credentials on first call")
        }
        let instance = Auth(credentials: creds)
        _instance = instance
        return instance
    }

    /// Clears the singleton so the next `getInstance` call starts fresh.
    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        _instance = nil
    }

    // MARK: - State
    private let state = ArtLock()
    private var credentials: AuthenticationConfig
    private var authData: AuthData = AuthData()
    private var inFlight: Task<AuthData, Error>?

    /// Seconds before `exp` at which an access token is renewed.
    static let renewalLeewaySeconds: Double = 30

    private init(credentials: AuthenticationConfig) {
        self.credentials = credentials
    }

    private func replaceCredentials(_ credentials: AuthenticationConfig) {
        state.sync { self.credentials = credentials }
    }

    private static func sameIdentity(_ a: AuthenticationConfig, _ b: AuthenticationConfig) -> Bool {
        a.orgTitle == b.orgTitle &&
            a.environment == b.environment &&
            a.projectKey == b.projectKey &&
            a.clientID == b.clientID
    }

    // MARK: - Authenticate
    /// Returns a valid token pair, getting or renewing it when needed.
    /// Concurrent calls share a single request; `forceAuth` renews a token
    /// that is still valid (used when reconnecting).
    ///
    /// Throws `AuthHttpError` when the server rejects the request, and
    /// `ARTError.authenticationFailed` when the credentials are incomplete,
    /// the server cannot be reached or does not answer within
    /// `AdkConfig.connectionTimeoutMs`, or the response holds no access
    /// token.
    public func authenticate(forceAuth: Bool = false) async throws -> AuthData {
        let task: Task<AuthData, Error> = state.sync {
            if let running = inFlight { return running }
            let started = Task { try await self.authenticateOnce(forceAuth: forceAuth) }
            inFlight = started
            return started
        }
        do {
            let result = try await task.value
            clearInFlight(task)
            return result
        } catch {
            clearInFlight(task)
            throw error
        }
    }

    private func clearInFlight(_ task: Task<AuthData, Error>) {
        state.sync {
            if inFlight == task { inFlight = nil }
        }
    }

    private func authenticateOnce(forceAuth: Bool) async throws -> AuthData {
        let cached = state.sync { authData }
        if !forceAuth,
           !cached.accessToken.isEmpty,
           !isTokenExpired(cached.accessToken) {
            return cached
        }
        readCredentialsProvider()
        let creds = state.sync { credentials }

        guard !creds.orgTitle.isEmpty,
              !creds.environment.isEmpty,
              !creds.projectKey.isEmpty else {
            throw ARTError.authenticationFailed("OrgTitle, Environment and ProjectKey are required")
        }

        // Client credentials renew by authenticating again, never through a
        // refresh token, even when an older server still returns one.
        if Auth.usesClientCredentials(creds) {
            return try await generateAuthToken(creds)
        }

        let refreshToken = state.sync { authData.refreshToken }
        if !getRefreshTokenExpiryInfo(refreshToken).expired {
            return try await refreshAuthToken(creds, refreshToken: refreshToken)
        }
        return try await generateAuthToken(creds)
    }

    /// Applies the `getCredentials` hook. Tokens issued to another identity
    /// are dropped, so they are never reused or refreshed.
    private func readCredentialsProvider() {
        guard let getCredentials = state.sync({ credentials.getCredentials }) else { return }
        let cred = getCredentials()
        state.sync {
            var next = credentials
            next.accessToken  = cred.accessToken
            next.clientID     = cred.clientID
            next.clientSecret = cred.clientSecret
            next.orgTitle     = cred.orgTitle
            next.environment  = cred.environment
            next.projectKey   = cred.projectKey
            if !Auth.sameIdentity(credentials, next) {
                authData = AuthData()
            }
            credentials = next
        }
    }

    private static func usesClientCredentials(_ credentials: AuthenticationConfig) -> Bool {
        !credentials.clientID.isEmpty && !credentials.clientSecret.isEmpty
    }

    // MARK: - Generate token
    private func generateAuthToken(_ credentials: AuthenticationConfig) async throws -> AuthData {
        let accessToken = credentials.accessToken ?? ""
        if accessToken.isEmpty && !Auth.usesClientCredentials(credentials) {
            throw ARTError.authenticationFailed("ClientID and ClientSecret required when AccessToken is absent")
        }

        var headers: [String: String] = [
            "Content-Type": "application/json",
            "X-Org":        credentials.orgTitle,
            "Environment":  credentials.environment,
            "ProjectKey":   credentials.projectKey,
        ]
        if Auth.usesClientCredentials(credentials) {
            headers["Client-Id"] = credentials.clientID
            headers["Client-Secret"] = credentials.clientSecret
        } else {
            headers["T-pass"] = accessToken
        }
        addPasscode(&headers, credentials)

        let data = try await post("/auth/token", headers: headers, body: nil, credentials: credentials)
        return try store(
            data, credentials,
            missingTokenMessage: "Authentication did not return an access token. Please sign in again."
        )
    }

    // MARK: - Refresh token
    private func refreshAuthToken(_ credentials: AuthenticationConfig, refreshToken: String) async throws -> AuthData {
        let accessToken = credentials.accessToken ?? ""
        if accessToken.isEmpty && credentials.clientID.isEmpty {
            throw ARTError.authenticationFailed("ClientID required when AccessToken is absent")
        }

        var headers: [String: String] = [
            "Content-Type": "application/json",
            "X-Org":        credentials.orgTitle,
            "Environment":  credentials.environment,
            "ProjectKey":   credentials.projectKey,
        ]
        if !credentials.clientID.isEmpty {
            headers["Client-Id"] = credentials.clientID
        }
        if !accessToken.isEmpty {
            headers["T-pass"] = accessToken
        }
        addPasscode(&headers, credentials)

        let data = try await post(
            "/auth/token/refresh", headers: headers,
            body: ["refresh_token": refreshToken], credentials: credentials
        )
        return try store(
            data, credentials,
            missingTokenMessage: "Authentication refresh did not return an access token. Please sign in again."
        )
    }

    private func addPasscode(_ headers: inout [String: String], _ credentials: AuthenticationConfig) {
        if let authToken = credentials.config?.authToken, !authToken.isEmpty {
            headers["X-pass"] = authToken
        }
    }

    /// Stores the tokens in `data`; throws `missingTokenMessage` as an
    /// `ARTError.authenticationFailed` when it holds no access token.
    private func store(
        _ data: [String: Any],
        _ credentials: AuthenticationConfig,
        missingTokenMessage: String
    ) throws -> AuthData {
        guard let accessToken = data["access_token"] as? String, !accessToken.isEmpty else {
            throw ARTError.authenticationFailed(missingTokenMessage)
        }
        let fresh = AuthData(
            accessToken: accessToken,
            refreshToken: Auth.usesClientCredentials(credentials) ? "" : data["refresh_token"] as? String ?? ""
        )
        state.sync { authData = fresh }
        return fresh
    }

    // MARK: - HTTP
    /// Sends an auth request and returns the `data` object of its response.
    /// Gives up after `AdkConfig.connectionTimeoutMs` (30 seconds by
    /// default).
    private func post(
        _ path: String,
        headers: [String: String],
        body: [String: Any]?,
        credentials: AuthenticationConfig
    ) async throws -> [String: Any] {
        guard let url = URL(string: "\(Constant.BASE_URL)\(path)") else {
            throw ARTError.authenticationFailed("Malformed auth URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let timeoutMs = credentials.config?.connectionTimeoutMs ?? 30_000
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await artData(for: req, timeoutMs: timeoutMs) {
                ARTError.authenticationFailed(
                    "Authentication timed out. Please check your connection and sign in again."
                )
            }
        } catch let error as ARTError {
            throw error
        } catch {
            throw ARTError.authenticationFailed(error.localizedDescription)
        }

        let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Keep both tokens: the gateway only lacked a WebSocket backend.
            if path.hasSuffix("/refresh"), http.statusCode == 500,
               let message = (json as? [String: Any])?["error"] as? String,
               message == "Failed to get WebSocket backend" {
                throw ARTError.serverError(message)
            }
            throw AuthHttpError(
                Auth.errorMessage(json) ?? Auth.statusText(http.statusCode),
                status: http.statusCode,
                body: json
            )
        }
        guard let object = json as? [String: Any] else {
            throw ARTError.authenticationFailed("Unexpected response from \(path)")
        }
        return object["data"] as? [String: Any] ?? [:]
    }

    private static func errorMessage(_ json: Any?) -> String? {
        guard let object = json as? [String: Any] else { return nil }
        for key in ["message", "error"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func statusText(_ status: Int) -> String {
        "HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))"
    }

    // MARK: - Public getters
    public func getAuthData() -> AuthData { state.sync { authData } }
    public func getCredentials() -> AuthenticationConfig { state.sync { credentials } }

    // MARK: - JWT helpers
    private func decodeJWTPayload(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { throw ARTError.authenticationFailed("Malformed JWT") }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        let pad = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: pad)
        guard let jsonData = Data(base64Encoded: b64) else {
            throw ARTError.authenticationFailed("Base64 decode failed")
        }
        guard let payload = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ARTError.authenticationFailed("JWT payload not a JSON object")
        }
        return payload
    }

    /// `true` when the token can't be decoded or expires within
    /// `renewalLeewaySeconds`.
    private func isTokenExpired(_ token: String) -> Bool {
        guard !token.isEmpty,
              let payload = try? decodeJWTPayload(token),
              let exp = (payload["exp"] as? NSNumber)?.doubleValue else { return true }
        return exp <= Date().timeIntervalSince1970 + Auth.renewalLeewaySeconds
    }
    private func getRefreshTokenExpiryInfo(_ token: String) -> RefreshInfo {
        guard !token.isEmpty else { return RefreshInfo(expired: true, exp: nil, remaining: 0) }
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let exp = Double(parts[1]) else {
            return RefreshInfo(expired: true, exp: nil, remaining: 0)
        }
        let now = Date().timeIntervalSince1970
        return RefreshInfo(expired: now >= exp, exp: exp, remaining: exp - now)
    }
    private struct RefreshInfo {
        var expired: Bool
        var exp: Double?
        var remaining: Double
    }
}
