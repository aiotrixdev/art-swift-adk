// Sources/ARTSdk/Types/AuthTypes.swift

import Foundation

// MARK: - AdkConfig
public struct AdkConfig: Encodable {
    public var uri: String
    public var authToken: String?
    /// Swift-specific credential hook, re-read on every authentication.
    /// Takes precedence over `Adk.setCredentials(_:)` and
    /// `autoLoadCredsFromJSON`.
    public var getCredentials: (() -> CredentialStore)?
    /// Directory containing `adk-services.json`. When
    /// `nil`, the file is looked up in the app bundle.
    public var root: String?
    /// Load credentials from `adk-services.json` on `connect()`.
    public var autoLoadCredsFromJSON: Bool

    public init(
        uri: String,
        authToken: String? = nil,
        getCredentials: (() -> CredentialStore)? = nil,
        root: String? = nil,
        autoLoadCredsFromJSON: Bool = false
    ) {
        self.uri = uri
        self.authToken = authToken
        self.getCredentials = getCredentials
        self.root = root
        self.autoLoadCredsFromJSON = autoLoadCredsFromJSON
    }
    enum CodingKeys: String, CodingKey {
            case uri, authToken, root, autoLoadCredsFromJSON
        }
}

// MARK: - CredentialStore
public struct CredentialStore: Encodable {
    public var environment: String
    public var projectKey: String
    public var orgTitle: String
    public var clientID: String
    public var clientSecret: String
    public var config: AdkConfig?
    public var accessToken: String?

    public init(
        environment: String = "",
        projectKey: String = "",
        orgTitle: String = "",
        clientID: String = "",
        clientSecret: String = "",
        config: AdkConfig? = nil,
        accessToken: String? = nil
    ) {
        self.environment = environment
        self.projectKey = projectKey
        self.orgTitle = orgTitle
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.config = config
        self.accessToken = accessToken
    }
}

// MARK: - AuthenticationConfig
public struct AuthenticationConfig: Encodable  {
    public var environment: String
    public var projectKey: String
    public var orgTitle: String
    public var clientID: String
    public var clientSecret: String
    public var config: AdkConfig?
    public var accessToken: String?
    public var getCredentials: (() -> CredentialStore)?

    public init(
        environment: String = "",
        projectKey: String = "",
        orgTitle: String = "",
        clientID: String = "",
        clientSecret: String = "",
        config: AdkConfig? = nil,
        accessToken: String? = nil,
        getCredentials: (() -> CredentialStore)? = nil
    ) {
        self.environment = environment
        self.projectKey = projectKey
        self.orgTitle = orgTitle
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.config = config
        self.accessToken = accessToken
        self.getCredentials = getCredentials
    }
    
    enum CodingKeys: String, CodingKey {
           case environment,
                projectKey,
                orgTitle,
                clientID,
                clientSecret,
                config,
                accessToken
       }
}

// MARK: - AuthData
public struct AuthData {
    public var accessToken: String
    public var refreshToken: String

    public init(accessToken: String = "", refreshToken: String = "") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

// MARK: - ConnectConfig
public struct ConnectConfig {
    public var restoreConnection: Bool

    public init(restoreConnection: Bool = false) {
        self.restoreConnection = restoreConnection
    }
}
