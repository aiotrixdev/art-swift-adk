import Foundation

/// Token management for the ART gateway.
///
/// - `authenticate()` is single-flight: concurrent callers (socket,
///   long-poll, REST, storage) share one in-flight token request, so a
///   refresh token is never rotated twice in parallel.
/// - Access tokens are renewed 30 s **before** `exp` (previously they were
///   treated as valid until 100 s *after* expiry).
public final class Auth {
    // MARK: - Singleton
    private static var _instance: Auth?
    private static let lock = NSLock()
    public static func getInstance(credentials: AuthenticationConfig? = nil) throws -> Auth {
        lock.lock()
        defer { lock.unlock() }
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
    // MARK: - Authenticate
    /// Returns a valid token pair, generating or refreshing it when needed.
    /// Concurrent calls share a single request.
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
        // Return cached token if still valid
        let cached = state.sync { authData }
        if !forceAuth,
           !cached.accessToken.isEmpty,
           !isTokenExpired(cached.accessToken) {
            return cached
        }
        // Refresh credentials via getCredentials hook if present
        if let getCredentials = state.sync({ credentials.getCredentials }) {
            let cred = getCredentials()
            state.sync {
                credentials.accessToken  = cred.accessToken
                credentials.clientID     = cred.clientID
                credentials.clientSecret = cred.clientSecret
                credentials.orgTitle     = cred.orgTitle
                credentials.environment  = cred.environment
                credentials.projectKey   = cred.projectKey
            }
        }
        let creds = state.sync { credentials }

        guard !creds.orgTitle.isEmpty,
              !creds.environment.isEmpty,
              !creds.projectKey.isEmpty else {
            throw ARTError.authenticationFailed("OrgTitle, Environment and ProjectKey are required")
        }

        // Use refresh token if still valid
        let refreshInfo = getRefreshTokenExpiryInfo(cached.refreshToken)
        if !refreshInfo.expired {
            return try await refreshAuthToken(creds, refreshToken: cached.refreshToken)
        }

        return try await generateAuthToken(creds)
    }

    // MARK: - Generate token
    private func generateAuthToken(_ credentials: AuthenticationConfig) async throws -> AuthData {
        if credentials.accessToken == nil || credentials.accessToken!.isEmpty {
            if credentials.clientID.isEmpty || credentials.clientSecret.isEmpty {
                throw ARTError.authenticationFailed("ClientID and ClientSecret required when AccessToken is absent")
            }
        }

        var headers: [String: String] = [
            "Client-Id":     credentials.clientID,
            "Client-Secret": credentials.clientSecret,
            "X-Org":         credentials.orgTitle,
            "Environment":   credentials.environment,
            "ProjectKey":    credentials.projectKey,
        ]
        if let token = credentials.accessToken, !token.isEmpty {
            headers["T-pass"] = token
        }
        if let authToken = credentials.config?.authToken {
            headers["X-pass"] = authToken
        }
        guard let url = URL(string: "\(Constant.BASE_URL)/auth/token") else {
            throw ARTError.authenticationFailed("Malformed auth token URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await ArtHTTP.session.data(for: req)
        try validateHTTPResponse(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tokenData = (json?["data"] as? [String: Any]) else {
            throw ARTError.authenticationFailed("Unexpected token response shape")
        }

        let fresh = AuthData(
            accessToken:  tokenData["access_token"]  as? String ?? "",
            refreshToken: tokenData["refresh_token"] as? String ?? ""
        )
        state.sync { authData = fresh }
        return fresh
    }

    // MARK: - Refresh token
    private func refreshAuthToken(_ credentials: AuthenticationConfig, refreshToken: String) async throws -> AuthData {
        if credentials.accessToken == nil || credentials.accessToken!.isEmpty {
            if credentials.clientID.isEmpty {
                throw ARTError.authenticationFailed("ClientID required when AccessToken is absent")
            }
        }

        var headers: [String: String] = [
            "X-Org":       credentials.orgTitle,
            "Environment": credentials.environment,
            "ProjectKey":  credentials.projectKey,
        ]
        // Conditional Client-Id + passcode/access-token headers on the refresh
        // path.
        if !credentials.clientID.isEmpty {
            headers["Client-Id"] = credentials.clientID
        }
        if let token = credentials.accessToken, !token.isEmpty {
            headers["T-pass"] = token
        }
        if let authToken = credentials.config?.authToken {
            headers["X-pass"] = authToken
        }

        guard let url = URL(string: "\(Constant.BASE_URL)/auth/token/refresh") else {
            throw ARTError.authenticationFailed("Malformed auth refresh URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        let (data, response) = try await ArtHTTP.session.data(for: req)

        if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 500 {
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errMsg = body["error"] as? String,
               errMsg == "Failed to get WebSocket backend" {
                // keep existing AccessToken + RefreshToken
                throw ARTError.serverError(errMsg)
            }
        }
        try validateHTTPResponse(response, data: data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tokenData = (json?["data"] as? [String: Any]) else {
            throw ARTError.authenticationFailed("Unexpected refresh response shape")
        }
        let fresh = AuthData(
            accessToken:  tokenData["access_token"]  as? String ?? "",
            refreshToken: tokenData["refresh_token"] as? String ?? ""
        )
        state.sync { authData = fresh }
        return fresh
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
    // MARK: - HTTP helper
    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode >= 200 && http.statusCode < 300 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ARTError.authenticationFailed(msg)
        }
    }
    private struct RefreshInfo {
        var expired: Bool
        var exp: Double?
        var remaining: Double
    }
}
