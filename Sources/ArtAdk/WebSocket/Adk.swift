// Sources/ArtAdk/WebSocket/Adk.swift
//
// Public entry point.

import Foundation

public enum AdkState: String {
    case paused, connected, connecting, stopped
}

open class Adk {

    // MARK: - Internal state
    public let socket: Socket
    private let lock = ArtLock()
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 5
    private var reconnectDelay: Double = 3000     // ms
    private let maxDelay: Double = 5000
    public  var myKeyPair: KeyPairType?
    private var adkConfig: AdkConfig?
    private var isPaused: Bool = false
    private var isConnectable: Bool = false
    /// Set once the server reports a billing / concurrency limit. Latches
    /// auto-reconnection off permanently — `handleOnClose` / `handleReconnection`
    /// early-return while this is true.
    private var isLimitExceeded: Bool = false
    private var reconnectTask: Task<Void, Never>?
    private var _state: AdkState = .stopped
    /// Credentials supplied via `setCredentials(_:)` or loaded from
    /// `adk-services.json`.
    private var credentialData: CredentialStore?
    /// Installed plugin APIs, keyed by plugin name.
    private var plugins: [String: Any] = [:]

    /// Connection state: `.connecting` while connecting or retrying,
    /// `.connected` once the server has bound the connection (`art_ready`),
    /// `.paused` after `pause()`, `.stopped` otherwise.
    public var state: AdkState { lock.sync { _state } }

    /// Listeners notified when the transport re-establishes after a drop
    /// (i.e. every successful connection *after* the first). Higher layers
    /// (agent / orchestrator threads) use this to re-attach their channel
    /// listeners. Keyed by token for `offReconnected(_:)`.
    private var reconnectHandlers: [UUID: () -> Void] = [:]
    private var hasConnectedOnce = false

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

        _ = socket.on("limitExceeded") { [weak self] data in
            guard let self else { return }
            let info = data as? [String: String]
            let code = info?["code"] ?? ""
            let errText = info?["error"] ?? ""
            let msg = code == "CONCURRENT_LIMIT_EXCEEDED"
                ? "[ART] Concurrent connection limit reached: \(errText). All reconnection attempts stopped. Call connect() again to retry."
                : "[ART] Billing limit reached: \(errText). All reconnection attempts permanently stopped."
            print(msg)
            self.lock.sync {
                self.isLimitExceeded = true
                self.isConnectable = false
                self._state = .stopped
            }
        }
    }

    // MARK: - connect
    /// Connects using, in order of precedence: `AdkConfig.getCredentials`,
    /// credentials from `setCredentials(_:)`, or `adk-services.json`
    /// (loaded when `autoLoadCredsFromJSON` is set, or — Swift
    /// compatibility — when no credentials were supplied at all).
    public func connect(config: ConnectConfig? = nil) async {
        if adkConfig?.getCredentials == nil {
            let hasCredentials = lock.sync { credentialData != nil }
            if adkConfig?.autoLoadCredsFromJSON == true || !hasCredentials {
                if let loaded = await loadConfig() {
                    lock.sync { credentialData = loaded }
                }
            }
        }

        lock.sync {
            isConnectable = true
            _state = .connecting
        }
        await initiateSocketConnection()
        if socket.isConnectionActive {
            lock.sync { if _state == .connecting { _state = .connected } }
        }
    }

    /// Supplies credentials for `connect()`. The
    /// `config` field is ignored. Takes effect on the first connection —
    /// the auth singleton keeps the credentials it was created with.
    public func setCredentials(_ credentials: CredentialStore) {
        var store = credentials
        store.config = nil
        lock.sync { credentialData = store }
    }

    // MARK: - pause
    /// Closes the connection and suspends auto-reconnection until
    /// `resume()`.
    public func pause() {
        let shouldPause: Bool = lock.sync {
            guard !isPaused else { return false }
            isPaused = true
            reconnectAttempts = maxReconnectAttempts
            _state = .paused
            return true
        }
        guard shouldPause else { return }
        reconnectTask?.cancel()
        Task { await socket.closeWebSocket() }
    }

    // MARK: - resume
    public func resume() async {
        let shouldResume: Bool = lock.sync {
            guard isPaused else { return false }
            isPaused = false
            reconnectAttempts = 0
            reconnectDelay    = 3000
            _state = .connecting
            return true
        }
        guard shouldResume else { return }
        try? await socket.connectWebSocket()
        if socket.isConnectionActive {
            lock.sync { if _state == .connecting { _state = .connected } }
        }
    }

    // MARK: - disconnect
    public func disconnect() async {
        lock.sync {
            isConnectable = false
            reconnectAttempts = maxReconnectAttempts
            _state = .stopped
        }
        reconnectTask?.cancel()
        await socket.closeWebSocket(clearConnection: true)
        socket.isConnectionActive = false
    }

    // MARK: - getState
    /// `paused`, `connected`, `retrying` or `stopped`.
    public func getState() -> String {
        let (paused, attempts) = lock.sync { (isPaused, reconnectAttempts) }
        if paused                                   { return "paused"    }
        if attempts >= maxReconnectAttempts         { return "stopped"   }
        if attempts > 0                             { return "retrying"  }
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

        } else if let store = lock.sync({ credentialData }) {

            authConfig = AuthenticationConfig(
                environment: store.environment,
                projectKey: store.projectKey,
                orgTitle: store.orgTitle,
                clientID: store.clientID,
                clientSecret: store.clientSecret,
                accessToken: store.accessToken
            )

        } else {
            ArtLog.error("Configuration not loaded — call setCredentials(_:), set AdkConfig.getCredentials, or provide adk-services.json")
            lock.sync { _state = .stopped }
            return
        }

        authConfig.config = adkConfig
        authConfig.getCredentials = adkConfig?.getCredentials
        await socket.initiateSocket(credentials: authConfig)
    }

    // MARK: - onReconnected (re-establish notifications)
    /// Registers `handler` to be called whenever the transport
    /// re-establishes after a drop (not on the first connect). Returns a
    /// token for `offReconnected(_:)`.
    @discardableResult
    public func onReconnected(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.sync { reconnectHandlers[id] = handler }
        return id
    }

    /// Removes a reconnect listener registered with `onReconnected(_:)`.
    public func offReconnected(_ id: UUID) {
        _ = lock.sync { reconnectHandlers.removeValue(forKey: id) }
    }

    // MARK: - Connection event handlers
    private func handleOnConnection(_ connection: ConnectionDetail) {
        let (wasReconnect, handlers) = lock.sync { () -> (Bool, [() -> Void]) in
            let wasReconnect = hasConnectedOnce
            hasConnectedOnce = true
            reconnectAttempts = 0
            reconnectDelay    = 3000
            if !isPaused { _state = .connected }
            return (wasReconnect, Array(reconnectHandlers.values))
        }
        onConnectedHook(connection)
        if wasReconnect {
            for handler in handlers { handler() }
        }
    }

    private func handleOnClose() {
        let shouldReconnect: Bool = lock.sync {
            // Billing / concurrency limit — never auto-reconnect.
            if isLimitExceeded { _state = .stopped; return false }
            // Paused: stay closed until resume().
            if isPaused { return false }
            guard isConnectable else { _state = .stopped; return false }
            _state = .connecting
            return true
        }
        guard shouldReconnect else { return }
        socket.isReConnecting = true
        handleReconnection()
    }

    private func handleReconnection() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let (delayMs, growDelay, attempt): (Double, Bool, Int) = self.lock.sync {
                if self.reconnectAttempts < self.maxReconnectAttempts {
                    self.reconnectAttempts += 1
                    return (self.reconnectDelay, true, self.reconnectAttempts)
                }
                return (self.maxDelay, false, self.reconnectAttempts)
            }
            if growDelay {
                ArtLog.info("Attempting to reconnect in \(delayMs / 1000) seconds... (Attempt \(attempt))")
            } else {
                ArtLog.warn("Max reconnection attempts reached. Will retry every \(self.maxDelay / 1000) seconds.")
            }
            try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
            let stillWanted = self.lock.sync { self.isConnectable && !self.isPaused && !self.isLimitExceeded }
            guard !Task.isCancelled, stillWanted else { return }
            await self.connect()
            if growDelay {
                // Linear backoff, capped at maxDelay
                self.lock.sync { self.reconnectDelay = min(self.reconnectDelay + 2000, self.maxDelay) }
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

    // MARK: - agent
    /// Returns an `Agent` handle for talking to the named agent over its
    /// dedicated `agent_com_<agentId>` channel. The agent subscribes lazily
    /// on first use of its thread.
    public func agent(_ agentId: String) -> Agent {
        return Agent(agentId, socket: socket)
    }

    // MARK: - orchestrator
    /// Returns an `Orchestrator` handle for the named top-level workflow
    /// over its dedicated `orch_com_<orchestratorId>` channel. Subscribes
    /// lazily on first call to `Orchestrator.thread(...)`; bypasses the
    /// channel-level `orchestratorEnabled` gate.
    public func orchestrator(_ orchestratorId: String) -> Orchestrator {
        return Orchestrator(orchestratorId, socket: socket)
    }

    // MARK: - connector
    /// Resolves and manages the authenticated user's profile for a
    /// connector. The profile lookup starts
    /// immediately; await `profile()` or call `updateProfile(_:)`.
    /// Throws when `connectorId` is empty.
    public func connector(_ connectorId: String) throws -> Connector {
        return try Connector(connectorId: connectorId, handler: socket)
    }

    // MARK: - Plugins
    /// Installs a plugin (e.g. `ArtAdkNotifications`) and returns its API.
    /// The plugin shares this instance's connection, REST client and auth.
    /// Retrieve it later with `plugin(_:as:)`.
    @discardableResult
    public func use<P: AdkPlugin>(_ plugin: P) -> P.API {
        let api = plugin.install(pluginContext())
        lock.sync { plugins[plugin.name] = api }
        return api
    }

    /// Returns an installed plugin's API by name, e.g.
    /// `adk.plugin("notifications", as: NotificationsApi.self)`.
    public func plugin<API>(_ name: String, as type: API.Type = API.self) -> API? {
        lock.sync { plugins[name] as? API }
    }

    private func pluginContext() -> AdkPluginContext {
        let socket = self.socket
        return AdkPluginContext(
            subscribe: { channel in try await socket.subscribe(channel: channel) },
            call: { endpoint, options in try await httpCall(endpoint, options: options) },
            getCredentials: { try Auth.getInstance().getCredentials() },
            baseUrl: { ArtGateway.origin }
        )
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
    /// Looks for the credentials file, in order: an absolute URL in
    /// `Constant.CONFIG_JSON_PATH`, `AdkConfig.root` + `CONFIG_FILE_NAME`
    /// then the app bundle. Keys: `Client-ID`,
    /// `Client-Secret`, `Environment`, `Org-Title`, `ProjectKey`.
    private func loadConfig() async -> CredentialStore? {
        guard let data = await readConfigData(),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            ArtLog.warn("Failed to load configuration (\(Constant.CONFIG_FILE_NAME))")
            return nil
        }
        func value(_ key: String) -> String { json[key] as? String ?? "" }
        return CredentialStore(
            environment:  value("Environment"),
            projectKey:   value("ProjectKey"),
            orgTitle:     value("Org-Title"),
            clientID:     value("Client-ID"),
            clientSecret: value("Client-Secret")
        )
    }

    private func readConfigData() async -> Data? {
        if let url = URL(string: Constant.CONFIG_JSON_PATH), url.scheme != nil {
            if url.isFileURL { return try? Data(contentsOf: url) }
            guard let result = try? await ArtHTTP.session.data(from: url),
                  let http = result.1 as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return result.0
        }
        if let root = adkConfig?.root, !root.isEmpty {
            let url = URL(fileURLWithPath: root).appendingPathComponent(Constant.CONFIG_FILE_NAME)
            if let data = try? Data(contentsOf: url) { return data }
        }
        let fileName = Constant.CONFIG_FILE_NAME as NSString
        let ext = fileName.pathExtension
        if let url = Bundle.main.url(
            forResource: fileName.deletingPathExtension,
            withExtension: ext.isEmpty ? nil : ext
        ) {
            return try? Data(contentsOf: url)
        }
        return nil
    }

    public func savePublicKey(_ keyPair: KeyPairType) async throws {
        let auth = try Auth.getInstance()
        _ = try await auth.authenticate()
        let authData = auth.getAuthData()
        let creds    = auth.getCredentials()

        guard let url = URL(string: "\(Constant.BASE_URL)/v1/update-publickey") else {
            throw ARTError.serverError("Malformed public key URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json",        forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(authData.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(creds.orgTitle,             forHTTPHeaderField: "X-Org")
        req.setValue(creds.environment,          forHTTPHeaderField: "Environment")
        req.setValue(creds.projectKey,           forHTTPHeaderField: "ProjectKey")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["public_key": keyPair.publicKey])

        let (_, response) = try await ArtHTTP.session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ARTError.serverError("Error updating keypair")
        }
        myKeyPair = keyPair
    }

    // MARK: - Key pair management
    /// Generates a key pair **and registers it** (uploads the public key and
    /// makes it the active pair).
    public func generateKeyPair() async throws -> KeyPairType {
        let keyPair = try CryptoBox.generateKeyPair()
        try await setKeyPair(keyPair)
        return keyPair
    }

    public func setKeyPair(_ keyPair: KeyPairType) async throws {
        guard !keyPair.publicKey.isEmpty, !keyPair.privateKey.isEmpty else {
            throw ARTError.encryptionError("Invalid KeyPair: keys must be non-empty strings")
        }
        try await savePublicKey(keyPair)
    }

    // MARK: - Profile
    /// Updates the authenticated user's profile (`POST /v1/update-profile`).
    /// Only non-`nil` fields are sent. Throws `HTTPCallError` on a non-2xx
    /// response.
    public func updateProfile(_ data: UpdateProfileData) async throws {
        try await httpCall("/v1/update-profile", options: CallApiProps(
            method: "POST",
            payload: data.payload
        ))
    }

    // MARK: - call  (generic REST helper)
    /// Calls an ART REST endpoint with a fresh token and returns the decoded
    /// JSON cast to `T`. Non-2xx responses throw `ARTError.serverError`
    /// ("API <endpoint> failed: <message>").
    public func call<T>(endpoint: String, options: CallApiProps = CallApiProps()) async throws -> T {
        let json: Any?
        do {
            json = try await httpCall(endpoint, options: options)
        } catch let error as HTTPCallError {
            throw ARTError.serverError(error.errorDescription ?? error.message)
        }

        guard let json else {
            if let empty = (() as? T) { return empty }
            throw ARTError.serverError("204 No Content but non-Void return type")
        }

        guard let result = json as? T else {
            throw ARTError.serverError("Response could not be cast to expected type")
        }
        return result
    }

    // MARK: - Storage
    // Unscoped storage (`config_id` defaults to the project key). Scoped
    // variants live on Agent, AgentThread, Orchestrator, OrchestratorThread
    // and Subscription.

    /// Uploads a local file. See `Storage.upload(fileURL:options:)`.
    @discardableResult
    public func upload(fileURL: URL, options: UploadOptions = UploadOptions()) async throws -> FileRef {
        try await Storage().upload(fileURL: fileURL, options: options)
    }

    /// Uploads in-memory bytes. See `Storage.upload(data:filename:contentType:options:)`.
    @discardableResult
    public func upload(
        data: Data,
        filename: String? = nil,
        contentType: String? = nil,
        options: UploadOptions = UploadOptions()
    ) async throws -> FileRef {
        try await Storage().upload(data: data, filename: filename, contentType: contentType, options: options)
    }

    /// Lists stored files.
    public func listFiles(options: ListOptions = ListOptions()) async throws -> StorageFileList {
        try await Storage().listFiles(options: options)
    }

    /// Fetches one file's metadata, including a signed `readUrl`.
    public func getFile(fileId: String, timeoutMs: Int? = nil) async throws -> StorageFile {
        try await Storage().getFile(fileId: fileId, timeoutMs: timeoutMs)
    }

    /// Deletes a file; `hard: true` removes it permanently.
    public func deleteFile(fileId: String, hard: Bool = false, timeoutMs: Int? = nil) async throws {
        try await Storage().deleteFile(fileId: fileId, hard: hard, timeoutMs: timeoutMs)
    }
}
