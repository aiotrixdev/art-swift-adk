import Foundation

public final class Auth {
    
    // MARK: - Singleton
    private static var _instance: Auth?
    private static let lock = NSLock()
    
    public static func getInstance(credentials: AuthenticationConfig? = nil) throws -> Auth {
        lock.lock()
        defer { lock.unlock() }
        if _instance == nil {
            guard let creds = credentials else {
                throw ARTError.forbidden("Auth not initialised – provide credentials on first call")
            }
            _instance = Auth(credentials: creds)
        }
        return _instance!
    }
    
    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        _instance = nil
    }
    
    // MARK: - State
    private var credentials: AuthenticationConfig
    private var authData: AuthData = AuthData()
    
    private init(credentials: AuthenticationConfig) {
        self.credentials = credentials
    }
    
    // MARK: - Authenticate
    public func authenticate(forceAuth: Bool = false) async throws -> AuthData {
        // Return cached token if still valid
        if !forceAuth,
           !authData.accessToken.isEmpty,
           !isTokenExpired(authData.accessToken) {
            return authData
        }
        
        // Refresh credentials via getCredentials hook if present
        if let getCredentials = credentials.getCredentials {
            let cred = getCredentials()
            credentials.accessToken  = cred.accessToken
            credentials.clientID     = cred.clientID
            credentials.clientSecret = cred.clientSecret
            credentials.orgTitle     = cred.orgTitle
            credentials.environment  = cred.environment
            credentials.projectKey   = cred.projectKey
        }
        
        guard !credentials.orgTitle.isEmpty,
              !credentials.environment.isEmpty,
              !credentials.projectKey.isEmpty else {
            throw ARTError.authenticationFailed("OrgTitle, Environment and ProjectKey are required")
        }
        
        // Use refresh token if still valid
        let refreshInfo = getRefreshTokenExpiryInfo(authData.refreshToken)
        if !refreshInfo.expired {
            return try await refreshAuthToken()
        }
        
        return try await generateAuthToken()
    }
    
    // MARK: - Generate token
    private func generateAuthToken() async throws -> AuthData {
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
        
        let url = URL(string: "\(Constant.BASE_URL)/auth/token")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTPResponse(response, data: data)
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tokenData = (json?["data"] as? [String: Any]) else {
            throw ARTError.authenticationFailed("Unexpected token response shape")
        }
        
        authData = AuthData(
            accessToken:  tokenData["access_token"]  as? String ?? "",
            refreshToken: tokenData["refresh_token"] as? String ?? ""
        )
        return authData
    }
    
    // MARK: - Refresh token
    private func refreshAuthToken() async throws -> AuthData {
        if credentials.accessToken == nil || credentials.accessToken!.isEmpty {
            if credentials.clientID.isEmpty {
                throw ARTError.authenticationFailed("ClientID required when AccessToken is absent")
            }
        }
        
        let headers: [String: String] = [
            "Client-Id":   credentials.clientID,
            "X-Org":       credentials.orgTitle,
            "Environment": credentials.environment,
            "ProjectKey":  credentials.projectKey,
        ]
        
        let url = URL(string: "\(Constant.BASE_URL)/auth/token/refresh")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": authData.refreshToken])
        
        let (data, response) = try await URLSession.shared.data(for: req)
        
        if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 500 {
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errMsg = body["error"] as? String,
               errMsg == "Failed to get WebSocket backend" {
                throw ARTError.serverError(errMsg)
            }
        }
        
        try validateHTTPResponse(response, data: data)
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tokenData = (json?["data"] as? [String: Any]) else {
            throw ARTError.authenticationFailed("Unexpected refresh response shape")
        }
        
        authData = AuthData(
            accessToken:  tokenData["access_token"]  as? String ?? "",
            refreshToken: tokenData["refresh_token"] as? String ?? ""
        )
        return authData
    }
    
    // MARK: - Public getters
    public func getAuthData() -> AuthData { authData }
    public func getCredentials() -> AuthenticationConfig { credentials }
    
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
    
    private func isTokenExpired(_ token: String) -> Bool {
        guard !token.isEmpty,
              let payload = try? decodeJWTPayload(token),
              let exp = payload["exp"] as? Double else { return true }
        return exp < (Date().timeIntervalSince1970 - 100)
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
