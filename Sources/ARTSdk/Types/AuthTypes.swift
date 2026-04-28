// Sources/ARTSdk/Types/AuthTypes.swift

import Foundation

// MARK: - AdkConfig
public struct AdkConfig {
    public var uri: String
    public var authToken: String?
    public var getCredentials: (() -> CredentialStore)?
    public var root: String?

    public init(
        uri: String,
        authToken: String? = nil,
        getCredentials: (() -> CredentialStore)? = nil,
        root: String? = nil
    ) {
        self.uri = uri
        self.authToken = authToken
        self.getCredentials = getCredentials
        self.root = root
    }
}

// MARK: - CredentialStore
public struct CredentialStore {
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
public struct AuthenticationConfig {
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
