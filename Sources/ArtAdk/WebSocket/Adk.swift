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
    /// The connection attempt in flight; concurrent `connect()` calls and
    /// reconnects join it.
    private var connectionAttempt: Task<Void, Error>?
    /// `(event, listener id)` pairs this instance registered on the shared
    /// socket; `disconnect()` removes them and `connect()` adds them back.
    private var socketListenerIds: [(event: String, id: UUID)] = []
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

        attachSocketListeners()
    }

    // MARK: - Socket listeners
    private func attachSocketListeners() {
        lock.sync {
            guard socketListenerIds.isEmpty else { return }
            socketListenerIds = [
                ("connection", socket.on("connection") { [weak self] data in
                    if let conn = data as? ConnectionDetail { self?.handleOnConnection(conn) }
                }),
                ("close", socket.on("close") { [weak self] _ in
                    self?.handleOnClose()
                }),
                ("limitExceeded", socket.on("limitExceeded") { [weak self] data in
                    self?.handleLimitExceeded(data)
                }),
                ("authenticationFailed", socket.on("authenticationFailed") { [weak self] data in
                    self?.handleAuthenticationFailed(data)
                }),
                ("connectionFailed", socket.on("connectionFailed") { [weak self] _ in
                    self?.handleConnectionFailed()
                }),
            ]
        }
    }

    private func detachSocketListeners() {
        let ids: [(event: String, id: UUID)] = lock.sync {
            let ids = socketListenerIds
            socketListenerIds = []
            return ids
        }
        for (event, id) in ids { socket.off(event, id: id) }
    }

    private func handleLimitExceeded(_ data: Any) {
        let info = data as? [String: String]
        let code = info?["code"] ?? ""
        let errText = info?["error"] ?? ""
        let msg = code == "CONCURRENT_LIMIT_EXCEEDED"
            ? "[ART] Concurrent connection limit reached: \(errText). All reconnection attempts stopped. Call connect() again to retry."
            : "[ART] Billing limit reached: \(errText). All reconnection attempts permanently stopped."
        ArtLog.error(msg)
        lock.sync {
            isLimitExceeded = true
            isConnectable = false
            _state = .stopped
        }
        cancelReconnect()
    }

    private func handleAuthenticationFailed(_ data: Any) {
        let detail = data as? AuthenticationFailedDetail
        let status = detail.map { $0.status != 0 ? " with HTTP \($0.status)" : "" } ?? ""
        ArtLog.error(
            "[ART] Authentication rejected\(status): \(detail?.error ?? "\(data)"). " +
            "Automatic reconnection has been stopped. Update the credentials and call connect() again."
        )
        lock.sync {
            isConnectable = false
            _state = .stopped
        }
        cancelReconnect()
        socket.isReConnecting = false
    }

    private func handleConnectionFailed() {
        lock.sync {
            isConnectable = false
            _state = .stopped
        }
        cancelReconnect()
    }

    private func cancelReconnect() {
        let task: Task<Void, Never>? = lock.sync {
            let task = reconnectTask
            reconnectTask = nil
            return task
        }
        task?.cancel()
    }

    // MARK: - connect
    /// Opens the connection to the ART server and returns once it is ready.
    ///
    /// Credentials come from, in order of precedence:
    /// `AdkConfig.getCredentials`, `setCredentials(_:)`, or
    /// `adk-services.json` (loaded when `autoLoadCredsFromJSON` is set, or
    /// when no credentials were supplied at all).
    ///
    /// This is also how to recover after `connectionFailed`: it clears the
    /// failure and starts over. A call made while an attempt is in flight
    /// joins it; a call while connected returns at once.
    ///
    /// Throws a `ConnectionError` when the attempt fails: code
    /// `AUTHENTICATION_FAILED` when the credentials are missing or the
    /// server rejects them (the `authenticationFailed` event fires too), or
    /// `CONNECTION_TIMEOUT` when the connection is not ready within
    /// `AdkConfig.connectionTimeoutMs`. Throws `ARTError.invalidArgument`
    /// when `connectionTimeoutMs` is not positive.
    public func connect(config: ConnectConfig? = nil) async throws {
        if let attempt = lock.sync({ connectionAttempt }) {
            return try await attempt.value
        }
        attachSocketListeners()
        if socket.isConnectionActive {
            lock.sync {
                isConnectable = true
                _state = .connected
            }
            return
        }
        cancelReconnect()
        lock.sync {
            isPaused = false
            isLimitExceeded = false
            reconnectAttempts = 0
            reconnectDelay = 3000
        }
        try socket.beginConnection(timeoutMs: adkConfig?.connectionTimeoutMs ?? 30_000)

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
        do {
            try await attemptConnection()
            lock.sync { _state = settledState() }
        } catch {
            lock.sync { _state = .stopped }
            throw error
        }
    }

    /// Opens the transport and waits until the connection is ready, sharing
    /// one attempt between concurrent callers. The readiness wait starts
    /// together with the attempt, so it bounds authentication too.
    private func attemptConnection() async throws {
        let attempt: Task<Void, Error> = lock.sync {
            if let running = connectionAttempt { return running }
            let socket = self.socket
            let started = Task {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.initiateSocketConnection() }
                    group.addTask { try await socket.wait() }
                    try await group.waitForAll()
                }
            }
            connectionAttempt = started
            return started
        }
        do {
            try await attempt.value
            lock.sync { if connectionAttempt == attempt { connectionAttempt = nil } }
        } catch {
            lock.sync { if connectionAttempt == attempt { connectionAttempt = nil } }
            throw error
        }
    }

    /// `state` after a connection attempt returned. Call with `lock` held.
    private func settledState() -> AdkState {
        if socket.isConnectionActive { return .connected }
        return isConnectable ? .connecting : .stopped
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
    /// Closes the connection, keeping subscriptions, and suspends
    /// auto-reconnection until `resume()`.
    ///
    /// The connection fails with `CONNECTION_PAUSED`, so active agent runs
    /// end with an error. No-op if already paused.
    public func pause() {
        let shouldPause: Bool = lock.sync {
            guard !isPaused else { return false }
            isPaused = true
            isConnectable = false
            reconnectAttempts = maxReconnectAttempts
            return true
        }
        guard shouldPause else { return }
        cancelReconnect()
        socket.failConnection(ConnectionError("The connection is paused.", code: "CONNECTION_PAUSED"))
        lock.sync { _state = .paused }
    }

    // MARK: - resume
    /// Reconnects after `pause()` (see `connect()`). No-op if not paused.
    public func resume() async throws {
        guard lock.sync({ isPaused }) else { return }
        try await connect()
    }

    // MARK: - disconnect
    /// Tears down the connection, subscriptions and interceptors, and
    /// removes this instance's own listeners from the shared socket.
    ///
    /// The connection fails with `CONNECTION_CLOSED`, so active agent runs
    /// end with an error. Call `connect()` to use the instance again;
    /// listeners the app added with `on(_:handler:)` stay registered.
    public func disconnect() async {
        lock.sync {
            isConnectable = false
            reconnectAttempts = maxReconnectAttempts
        }
        cancelReconnect()
        socket.failConnection(ConnectionError("The connection was closed.", code: "CONNECTION_CLOSED"))
        await socket.closeWebSocket(clearConnection: true)
        lock.sync { _state = .stopped }
        socket.isConnectionActive = false
        detachSocketListeners()
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
    private func initiateSocketConnection() async throws {

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
            let error = ConnectionError(
                "Connection credentials are missing. Please sign in again.",
                code: "AUTHENTICATION_FAILED"
            )
            socket.failConnection(error)
            throw error
        }

        authConfig.config = adkConfig
        authConfig.getCredentials = adkConfig?.getCredentials
        try await socket.initiateSocket(credentials: authConfig)
        try await socket.wait()
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
        cancelReconnect()
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
            // The attempt in flight reports its own outcome.
            if connectionAttempt != nil { return false }
            _state = .connecting
            return true
        }
        guard shouldReconnect else { return }
        socket.isReConnecting = true
        handleReconnection()
    }

    /// Schedules the next reconnect attempt; after `maxReconnectAttempts`
    /// the connection fails with `CONNECTION_LOST`.
    private func handleReconnection() {
        enum Step { case skip, giveUp, retry(delayMs: Double, attempt: Int) }
        let step: Step = lock.sync {
            if isLimitExceeded || !isConnectable || isPaused || reconnectTask != nil { return .skip }
            guard reconnectAttempts < maxReconnectAttempts else { return .giveUp }
            reconnectAttempts += 1
            let delayMs = reconnectDelay
            let attempt = reconnectAttempts
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
                guard let self, !Task.isCancelled else { return }
                let stillWanted: Bool = self.lock.sync {
                    self.reconnectTask = nil
                    guard self.isConnectable, !self.isPaused, !self.isLimitExceeded else { return false }
                    self._state = .connecting
                    // Linear backoff, capped at maxDelay
                    self.reconnectDelay = min(self.reconnectDelay + 2000, self.maxDelay)
                    return true
                }
                guard stillWanted else { return }
                do {
                    try await self.attemptConnection()
                    self.lock.sync { self._state = self.settledState() }
                } catch {
                    if self.lock.sync({ self.isConnectable }) { self.handleReconnection() }
                }
            }
            return .retry(delayMs: delayMs, attempt: attempt)
        }
        switch step {
        case .skip:
            return
        case .giveUp:
            socket.failConnection(ConnectionError(
                "The connection could not be restored. Please reconnect to check your execution.",
                code: "CONNECTION_LOST"
            ))
        case .retry(let delayMs, let attempt):
            ArtLog.info("Attempting to reconnect in \(delayMs / 1000) seconds... (Attempt \(attempt))")
        }
    }

    // MARK: - on / off  (event subscriptions)
    /// Registers `handler` for a connection event: `connection`
    /// (`ConnectionDetail`), `open`, `close`, `error`, `limitExceeded`,
    /// `authenticationFailed` (`AuthenticationFailedDetail`) or
    /// `connectionFailed` (`ConnectionError`).
    ///
    /// `close` reports a closure the ADK may still recover from by
    /// reconnecting. `connectionFailed` reports that the connection is gone
    /// for good: the credentials were rejected, a limit was reached, the
    /// connection was paused or closed, or it could not be restored in
    /// time. Active agent runs then end with an `agent_error` whose details
    /// have `source: connection`, and waits, sends and subscriptions throw
    /// the same `ConnectionError`. Fix the cause and call `connect()` to
    /// recover. Returns a token for `off(_:id:)`.
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
    ///
    /// `agentId` is the agent's slug, optionally pinned to a named build
    /// (`my-agent@release2`); anything else throws
    /// `ARTError.invalidArgument` (see `validateExecutionReference(_:)`).
    public func agent(_ agentId: String) throws -> Agent {
        return try Agent(agentId, socket: socket)
    }

    // MARK: - orchestrator
    /// Returns an `Orchestrator` handle for the named top-level workflow
    /// over its dedicated `orch_com_<orchestratorId>` channel. Subscribes
    /// lazily on first call to `Orchestrator.thread(...)`; bypasses the
    /// channel-level `orchestratorEnabled` gate.
    ///
    /// `orchestratorId` is a slug, optionally with `@buildname`, like the
    /// agent id in `agent(_:)`.
    public func orchestrator(_ orchestratorId: String) throws -> Orchestrator {
        return try Orchestrator(orchestratorId, socket: socket)
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
    /// Closes the connection without clearing subscriptions. The connection
    /// fails with `CONNECTION_CLOSED` and does not reconnect until
    /// `connect()` is called.
    public func closeWebSocket() async {
        lock.sync { isConnectable = false }
        cancelReconnect()
        socket.failConnection(ConnectionError("The connection was closed.", code: "CONNECTION_CLOSED"))
        await socket.closeWebSocket()
        lock.sync { _state = .stopped }
    }

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
    // Temporary media for a thread (`options.threadId` is required), owned
    // by `configId` — the project key by default. Scoped variants live on
    // Agent, AgentThread, Orchestrator, OrchestratorThread and Subscription.

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

    /// Lists the files in `options.threadId` (required) that
    /// `options.configId` (the project key by default) can access.
    public func listFiles(options: ListOptions = ListOptions()) async throws -> StorageFileList {
        try await Storage().listFiles(options: options)
    }

    /// Fetches the metadata and a read URL of the file `fileId` in
    /// `threadId`.
    public func getFile(fileId: String, threadId: String, timeoutMs: Int? = nil) async throws -> StorageFile {
        try await Storage().getFile(fileId: fileId, threadId: threadId, timeoutMs: timeoutMs)
    }

    /// Deletes a file. `hard` is ignored: files are always removed.
    public func deleteFile(fileId: String, hard: Bool = false, timeoutMs: Int? = nil) async throws {
        try await Storage().deleteFile(fileId: fileId, hard: hard, timeoutMs: timeoutMs)
    }
}
