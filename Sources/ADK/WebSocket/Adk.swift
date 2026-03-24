// Sources/ARTSdk/WebSocket/Adk.swift

import Foundation

public enum AdkState: String {
    case paused, connected, connecting, stopped
}

open class Adk {

    // MARK: - Internal state
    public let socket: Socket
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 5
    private var reconnectDelay: Double = 3000     // ms
    private let maxDelay: Double = 5000
    public  var myKeyPair: KeyPairType?
    private var adkConfig: AdkConfig?
    private var isPaused: Bool = false
    private var isConnectable: Bool = false
    private var reconnectTask: Task<Void, Never>?
    public private(set) var state: AdkState = .stopped

    // MARK: - Init
    public init(config: AdkConfig? = nil) {

        let rawUrl = config?.uri ?? ""

        Constant.BASE_URL = "https://\(rawUrl)"
        Constant.WS_URL   = "wss://\(rawUrl)/v1/connect"
        Constant.SSE_URL  = "https://\(rawUrl)/v1/connect/sse"
        Constant.LPOLL    = "https://\(rawUrl)/v1/connect/longpoll"

        self.adkConfig = config

        self.socket = Socket.getInstance(
            encrypt: { data, _ in
                return data
            },
            decrypt: { data, _ in
                return data
            }
        )

        socket.encrypt = { [weak self] data, pubKey in
            guard let self else {
                throw ARTError.encryptionError("Adk deallocated")
            }
            return try await self.encrypt(data, recipientPublicKey: pubKey)
        }

        socket.decrypt = { [weak self] data, pubKey in
            guard let self else {
                throw ARTError.decryptionError("Adk deallocated")
            }
            return try await self.decrypt(data, senderPublicKey: pubKey)
        }

        _ = socket.on("connection") { [weak self] data in
            if let conn = data as? ConnectionDetail {
                self?.handleOnConnection(conn)
            }
        }

        _ = socket.on("close") { [weak self] _ in
            self?.handleOnClose()
        }
    }

    // MARK: - connect
    public func connect(config: ConnectConfig? = nil) async {
        isConnectable = true
        state = .connecting
        await initiateSocketConnection()
        state = .connected
    }

    // MARK: - pause
    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        reconnectAttempts = maxReconnectAttempts
        Task { await socket.closeWebSocket()
            state = .paused
        }
    }

    // MARK: - resume
    public func resume() async {
        guard isPaused else { return }
        isPaused = false
        reconnectAttempts = 0
        reconnectDelay    = 3000
        state = .connecting
        try? await socket.connectWebSocket()
        state = .connected
    }

    // MARK: - disconnect
    public func disconnect() async {
        isConnectable = false
        reconnectAttempts = maxReconnectAttempts
        reconnectTask?.cancel()
        await socket.closeWebSocket(clearConnection: true)
        state = .stopped
        socket.isConnectionActive = false
        socket.pendingSendMessages = []
    }

    // MARK: - getState
    public func getState() -> String {
        if isPaused                                 { return "paused"    }
        if reconnectAttempts >= maxReconnectAttempts { return "stopped"   }
        if reconnectAttempts > 0                    { return "retrying"  }
        if socket.isConnectionActive                { return "connected" }
        return "stopped"
    }

    // MARK: - Private: initiate socket connection
    private func initiateSocketConnection() async {

        var authConfig: AuthenticationConfig

        if let provider = adkConfig?.getCredentials {

            let store = provider()

            authConfig = AuthenticationConfig(
                environment: store.environment,
                projectKey: store.projectKey,
                orgTitle: store.orgTitle,
                clientID: store.clientID,
                clientSecret: store.clientSecret
            )

            authConfig.accessToken = store.accessToken

        } else {

            authConfig = await loadConfig()
        }

        authConfig.config = adkConfig
        authConfig.getCredentials = adkConfig?.getCredentials
        LogTracer.printDATA(authConfig, title: "Auth Config")
        await socket.initiateSocket(credentials: authConfig)
    }

    // MARK: - Connection event handlers
    private func handleOnConnection(_ connection: ConnectionDetail) {
        reconnectAttempts = 0
        reconnectDelay    = 3000
        onConnectedHook(connection)
    }

    private func handleOnClose() {
        guard isConnectable else { return }
        socket.isReConnecting = true
        handleReconnection()
    }

    private func handleReconnection() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            if self.reconnectAttempts < self.maxReconnectAttempts {
                self.reconnectAttempts += 1
                print("[ART] Reconnecting in \(self.reconnectDelay / 1000)s (attempt \(self.reconnectAttempts))")
                try? await Task.sleep(nanoseconds: UInt64(self.reconnectDelay * 1_000_000))
                await self.connect()
                self.reconnectDelay = min(self.reconnectDelay + 2000, self.maxDelay)
            } else {
                print("[ART] Max reconnect attempts reached. Retrying in \(self.maxDelay / 1000)s")
                try? await Task.sleep(nanoseconds: UInt64(self.maxDelay * 1_000_000))
                await self.connect()
            }
        }
    }

    // MARK: - on / off  (event subscriptions)
    @discardableResult
    public func on(_ event: String, handler: @escaping (Any) -> Void) -> UUID {
        return socket.on(event, handler: handler)
    }
    public func off(_ event: String, id: UUID) { socket.off(event, id: id) }

    // MARK: - subscribe
    public func subscribe(channel: String) async throws -> BaseSubscription {
        return try await socket.subscribe(channel: channel)
    }

    // MARK: - intercept
    public func intercept(
        interceptor: String,
        fn: @escaping ([String: Any], @escaping (Any) -> Void, @escaping (String) -> Void) -> Void
    ) async throws -> Interception {
        return try await socket.intercept(interceptor: interceptor, fn: fn)
    }

    // MARK: - closeWebSocket
    public func closeWebSocket() async { await socket.closeWebSocket() }

    // MARK: - pushForSecureLine (protected helper for child classes)
    public func pushForSecureLine(event: String, data: Any, listen: Bool = false) async throws -> Any? {
        return try await socket.pushForSecureLine(event: event, data: data, listen: listen)
    }

    // MARK: - onConnectedHook  (override in subclass)
    open func onConnectedHook(_ connection: ConnectionDetail) {}

    // MARK: - Crypto (override to customise)
    open func encrypt(_ data: String, recipientPublicKey: String) async throws -> String {
        guard let kp = myKeyPair else {
            throw ARTError.encryptionError("Please generate a new key pair or set an existing key pair")
        }
        return try CryptoBox.encrypt(message: data, publicKey: recipientPublicKey, privateKey: kp.privateKey)
    }

    open func decrypt(_ data: String, senderPublicKey: String) async throws -> String {
        guard let kp = myKeyPair else {
            throw ARTError.decryptionError("Please generate a new key pair or set an existing key pair")
        }
        return try CryptoBox.decrypt(encryptedData: data, publicKey: senderPublicKey, privateKey: kp.privateKey)
    }

    
    // MARK: - loadConfig  (reads adk-services.json)
    private func loadConfig() async -> AuthenticationConfig {
        guard let url = URL(string: Constant.CONFIG_JSON_PATH),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return AuthenticationConfig()
        }
        return AuthenticationConfig(
            environment:  json["Environment"]  ?? "",
            projectKey:   json["ProjectKey"]   ?? "",
            orgTitle:     json["Org-Title"]    ?? "",
            clientID:     json["Client-ID"]    ?? "",
            clientSecret: json["Client-Secret"] ?? ""
        )
    }
    
    public func savePublicKey(_ keyPair: KeyPairType) async throws {
        let auth = try Auth.getInstance()
        _ = try await auth.authenticate()
        let authData = auth.getAuthData()
        let creds    = auth.getCredentials()

        var req = URLRequest(url: URL(string: "\(Constant.BASE_URL)/v1/update-publickey")!)
        req.httpMethod = "POST"
        req.setValue("application/json",        forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(authData.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(creds.orgTitle,             forHTTPHeaderField: "X-Org")
        req.setValue(creds.environment,          forHTTPHeaderField: "Environment")
        req.setValue(creds.projectKey,           forHTTPHeaderField: "ProjectKey")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["public_key": keyPair.publicKey])

        let (data, response) = try await URLSession.shared.data(for: req)
        LogTracer.printJSONData(data, title: "✅ SavePublicKey Response")

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ARTError.serverError("Error updating keypair")
        }
        myKeyPair = keyPair
    }
    
    // MARK: - Key pair management
    public func generateKeyPair() async throws -> KeyPairType {
         var keyPair=try CryptoBox.generateKeyPair()
         try?await setKeyPair(keyPair)
        return keyPair
    }

    public func setKeyPair(_ keyPair: KeyPairType) async throws {
        guard !keyPair.publicKey.isEmpty, !keyPair.privateKey.isEmpty else {
            throw ARTError.encryptionError("Invalid KeyPair: keys must be non-empty strings")
        }
        try await savePublicKey(keyPair)
    }


    // MARK: - call  (generic REST helper – mirrors adk.ts call())
    public func call<T>(endpoint: String, options: CallApiProps = CallApiProps()) async throws -> T {
        let auth = try Auth.getInstance()
        _ = try await auth.authenticate()
        let authData = auth.getAuthData()
        let creds    = auth.getCredentials()

        var urlStr = "\(Constant.BASE_URL)\(endpoint)"
        if let params = options.queryParams {
            let qs = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            urlStr += "?\(qs)"
        }

        var req = URLRequest(url: URL(string: urlStr)!)
        req.httpMethod = options.method.uppercased()
        req.setValue("Bearer \(authData.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json",               forHTTPHeaderField: "Accept")
        req.setValue(creds.orgTitle,                   forHTTPHeaderField: "X-Org")
        req.setValue(creds.environment,                forHTTPHeaderField: "Environment")
        req.setValue(creds.projectKey,                 forHTTPHeaderField: "ProjectKey")
        options.headers?.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        if let payload = options.payload {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ARTError.serverError("No HTTP response")
        }

        if http.statusCode == 204 {
            if let empty = (() as? T) { return empty }
            throw ARTError.serverError("204 No Content but non-Void return type")
        }

        guard http.statusCode >= 200 && http.statusCode < 300 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ARTError.serverError("API \(endpoint) failed: \(msg)")
        }

        guard let result = try JSONSerialization.jsonObject(with: data) as? T else {
            throw ARTError.serverError("Response could not be cast to expected type")
        }
        return result
    }

}
