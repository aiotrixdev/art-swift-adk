// Sources/ArtAdk/WebSocket/Socket.swift


import Foundation

// MARK: - WebSocket event callbacks
public struct WebSocketEvents {
    public var onOpen:       ((URLSessionWebSocketTask.CloseCode?) -> Void)?
    public var onError:      ((Error) -> Void)?
    public var onClose:      ((URLSessionWebSocketTask.CloseCode, String?) -> Void)?
    public var onConnection: ((ConnectionDetail) -> Void)?
    /// Fired when the server rejects the connection for a billing / concurrency
    /// limit (`CONNECTION_MINUTES_LIMIT_EXCEEDED` / `CONCURRENT_LIMIT_EXCEEDED`).
    public var onLimitExceeded: ((_ code: String, _ error: String) -> Void)?
    /// Fired when authentication fails for good; reconnection stops until
    /// the app connects again.
    public var onAuthenticationFailed: ((AuthenticationFailedDetail) -> Void)?
    /// Fired when the connection fails for good; reconnection stops until
    /// the app connects again.
    public var onConnectionFailed: ((ConnectionError) -> Void)?
}

/// A `wait()` call waiting for the connection.
private struct ConnectionWaiter {
    let continuation: CheckedContinuation<Void, Error>
    var timer: Task<Void, Never>?
}

/// A control request on the `art_secure` line waiting for its reply.
private struct PendingSecureRequest {
    let continuation: CheckedContinuation<Any?, Error>
    let timer: Task<Void, Never>
}

/// A `connectWebSocket` call waiting for its WebSocket to open.
private struct PendingHandshake {
    let task: URLSessionWebSocketTask
    let continuation: CheckedContinuation<Void, Error>
}

// MARK: - Socket (singleton)
public final class Socket: NSObject, IWebsocketHandler {
    private static let lock = NSLock()

    // MARK: Singleton
    private static var _instance: Socket?
    // MARK: - State
    private var websocket: URLSessionWebSocketTask?
    /// `connectionGeneration` at the time `websocket` was opened.
    private var websocketGeneration = 0
    private var pendingHandshake: PendingHandshake?
    private var credentials: AuthenticationConfig = AuthenticationConfig()
    private var subscriptions: [String: BaseSubscription] = [:]
    private var interceptors:  [String: Interception]     = [:]
    private var connection: ConnectionDetail? = nil
    private var _isConnectionActive = false
    private var heartbeatTask: Task<Void, Never>?
    private var secureRequests: [String: PendingSecureRequest] = [:]
    private var pendingIncomingMessages: [String: [(event: String, payload: [String: Any])]] = [:]
    public var encrypt: (String, String) async throws -> String
    public var decrypt: (String, String) async throws -> String
    private var pullSource: String = "socket"  // "socket" | "sse" | "http"
    private var pushSource: String = "socket"
    private var lpClient: LongPollClient!
    private var isConnecting = false
    private var _isReConnecting = false
    private var autoReconnect = false

    private var sseTask: Task<Void, Never>?
    /// Identifies the live event stream; its callbacks are ignored once
    /// another stream or a teardown replaced it.
    private var sseStreamId: UUID?
    private var urlSession: URLSession!

    /// `true` once the server has confirmed the connection (`art_ready`);
    /// `false` while only the long-poll fallback's local connection exists.
    private var connectionBound = false
    /// Access token the server currently authorises this connection with.
    private var authorizedAccessToken = ""
    private var authorizationRefresh: Task<Void, Error>?
    /// Why the connection failed; set until `beginConnection` starts over.
    private var connectionFailure: ConnectionError?
    /// Bumped on every new attempt and failure, so callbacks of an older
    /// transport are ignored.
    private var connectionGeneration = 0
    private var connectionTimeoutMs = 30_000

    // MARK: - Event emitter
    private let emitter = EventEmitter()

    // MARK: - Connection waiters
    private var connectionWaiters: [UUID: ConnectionWaiter] = [:]
    private let socketLock = NSRecursiveLock()

    /// Thread-safe access to shared state. Wraps lock/unlock in a nonisolated
    /// synchronous context so Swift 6 doesn't warn about locks in async code.
    private nonisolated func withSocketLock<T>(_ body: () throws -> T) rethrows -> T {
        socketLock.lock()
        defer { socketLock.unlock() }
        return try body()
    }

    /// Whether the socket currently has an active (server-confirmed or
    /// local fallback) connection.
    public var isConnectionActive: Bool {
        get { withSocketLock { _isConnectionActive } }
        set { withSocketLock { _isConnectionActive = newValue } }
    }

    /// `true` during a reconnect attempt (forces a token renewal).
    internal var isReConnecting: Bool {
        get { withSocketLock { _isReConnecting } }
        set { withSocketLock { _isReConnecting = newValue } }
    }

    // MARK: - Init (private)
    private init(
        encrypt: @escaping (String, String) async throws -> String,
        decrypt: @escaping (String, String) async throws -> String
    ) {
        self.encrypt = encrypt
        self.decrypt = decrypt
        super.init()
        self.urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

        var pollOptions = LongPollOptions(
            endpoint: Constant.LPOLL,
            getAuthHeaders: { [weak self] in
                guard let self else { return [:] }
                let auth = try self.sessionAuth()
                let authData = try await auth.authenticate()
                let creds    = auth.getCredentials()
                return [
                    "Authorization": "Bearer \(authData.accessToken)",
                    "X-Org":         creds.orgTitle,
                    "Environment":   creds.environment,
                    "ProjectKey":    creds.projectKey,
                ]
            },
            onMessages: { [weak self] msgs in
                self?.processIncomingMessages(msgs)
            },
            onError: { [weak self] error in
                // The poll loop stops itself on rejected credentials.
                if isTerminalAuthError(error) {
                    self?.stopAfterAuthenticationFailure(error)
                }
            }
        )
        pollOptions.onResponse = { [weak self] in self?.openLocalFallbackConnection() }
        self.lpClient = LongPollClient(opts: pollOptions)
    }

    public static func getInstance(
        encrypt: @escaping (String, String) async throws -> String,
        decrypt: @escaping (String, String) async throws -> String
    ) -> Socket {
        lock.lock(); defer { lock.unlock() }
        if _instance == nil {
            _instance = Socket(encrypt: encrypt, decrypt: decrypt)
        }
        return _instance!
    }

    // MARK: - Connection lifecycle
    /// Starts a new connection attempt: clears an earlier failure and sets
    /// the readiness timeout to `timeoutMs` milliseconds. `Adk.connect()`
    /// calls this before connecting.
    ///
    /// Throws `ARTError.invalidArgument` when `timeoutMs` is not positive.
    public func beginConnection(timeoutMs: Int = 30_000) throws {
        guard timeoutMs > 0 else {
            throw ARTError.invalidArgument("connectionTimeoutMs must be positive")
        }
        let stale: PendingHandshake? = withSocketLock {
            connectionTimeoutMs = timeoutMs
            connectionFailure = nil
            connectionGeneration += 1
            // An attempt still in flight belongs to the old generation and
            // will be cancelled; it must not block this one.
            isConnecting = false
            let stale = pendingHandshake
            pendingHandshake = nil
            return stale
        }
        stale?.continuation.resume(throwing: Socket.connectionCancelled())
    }

    private static func connectionCancelled() -> ConnectionError {
        ConnectionError("Connection attempt cancelled.", code: "CONNECTION_CANCELLED")
    }

    /// Ends the connection with `error` and stops automatic reconnection.
    ///
    /// Closes the transport, fails pending connection waits and control
    /// requests with `error`, and emits `connectionFailed`. Waits and sends
    /// keep throwing `error` until `beginConnection` starts a new attempt.
    /// Only the first failure counts; later calls do nothing.
    public func failConnection(_ error: ConnectionError) {
        let teardown: (Teardown, [ConnectionWaiter], [PendingSecureRequest])? = withSocketLock {
            guard connectionFailure == nil else { return nil }
            connectionFailure = error
            connectionGeneration += 1
            _isReConnecting = false
            autoReconnect = false
            connection = nil
            let waiters = Array(connectionWaiters.values)
            let requests = Array(secureRequests.values)
            connectionWaiters.removeAll()
            secureRequests.removeAll()
            return (takeTransportLocked(), waiters, requests)
        }
        guard let (transport, waiters, requests) = teardown else { return }
        stop(transport)
        transport.handshake?.continuation.resume(throwing: error)
        for waiter in waiters {
            waiter.timer?.cancel()
            waiter.continuation.resume(throwing: error)
        }
        for request in requests {
            request.timer.cancel()
            request.continuation.resume(throwing: error)
        }
        emitter.emit("connectionFailed", error)
    }

    @discardableResult
    public func onConnectionFailure(_ listener: @escaping (ConnectionError) -> Void) -> UUID {
        emitter.on("connectionFailed") { data in
            if let error = data as? ConnectionError { listener(error) }
        }
    }

    public func offConnectionFailure(_ id: UUID) {
        emitter.off("connectionFailed", id: id)
    }

    /// The live transport, detached from the socket's state.
    private struct Teardown {
        let websocket: URLSessionWebSocketTask?
        let sse: Task<Void, Never>?
        let heartbeat: Task<Void, Never>?
        let handshake: PendingHandshake?
    }

    /// Resets the connection flags and detaches the transport. Must be
    /// called with the socket lock held; stop the result with `stop(_:)`
    /// and end its `handshake`.
    private func takeTransportLocked() -> Teardown {
        let teardown = Teardown(
            websocket: websocket, sse: sseTask, heartbeat: heartbeatTask, handshake: pendingHandshake
        )
        websocket = nil
        sseTask = nil
        sseStreamId = nil
        heartbeatTask = nil
        pendingHandshake = nil
        _isConnectionActive = false
        isConnecting = false
        connectionBound = false
        return teardown
    }

    private func stop(_ teardown: Teardown) {
        lpClient.stop()
        teardown.sse?.cancel()
        teardown.heartbeat?.cancel()
        teardown.websocket?.cancel(with: .normalClosure, reason: nil)
    }

    /// The error ending an attempt started at `generation`, when a failure
    /// or a newer attempt replaced it.
    private func replacement(of generation: Int) -> Error? {
        withSocketLock {
            guard connectionGeneration != generation else { return nil }
            return connectionFailure ?? Socket.connectionCancelled()
        }
    }

    /// Rethrows `error` (or the failure that replaced the attempt) unless
    /// the attempt started at `generation` is still current.
    private func throwIfReplaced(_ generation: Int, _ error: Error) throws {
        let (current, failure) = withSocketLock { (connectionGeneration, connectionFailure) }
        if current != generation { throw failure ?? error }
        if let failure { throw failure }
    }

    // MARK: - initiateSocket
    /// Opens the connection, falling back from WebSocket to SSE to
    /// long-poll. Safe to call repeatedly.
    ///
    /// Throws the `ConnectionError` once the connection has failed,
    /// including when the server rejected the credentials.
    public func initiateSocket(credentials: AuthenticationConfig) async throws {
        let (generation, failure, isOpen) = withSocketLock {
            (connectionGeneration, connectionFailure, websocket != nil && _isConnectionActive)
        }
        if let failure { throw failure }
        if isOpen { return }
        withSocketLock { self.credentials = credentials }

        // 1.  WebSocket
        do {
            try await connectWebSocket()
            withSocketLock { pullSource = "socket"; pushSource = "socket" }
            return
        } catch {
            // A failure, or a newer attempt, replaced this one: no fallback.
            try throwIfReplaced(generation, error)
            ArtLog.warn("WebSocket failed, falling back to SSE: \(error)")
        }

        // 2. SSE
        do {
            try await connectSSE()
            withSocketLock { pullSource = "sse"; pushSource = "http" }
            return
        } catch {
            try throwIfReplaced(generation, error)
            ArtLog.warn("SSE failed, falling back to HTTP poll: \(error)")
        }

        // 3. LongPoll
        let connectionId = withSocketLock { () -> String? in
            pullSource = "http"; pushSource = "http"
            return connection?.connectionId
        }
        // Long-poll has no `art_ready` handshake to bind a connection, so a
        // local one is opened once a poll is answered; until then `wait()`
        // keeps waiting, and times out when the server can't be reached.
        lpClient.start(connectionId: connectionId)
    }


    // MARK: - connectWebSocket
    /// Opens the WebSocket and returns once it is open, emitting `open`. The
    /// connection becomes active once the server confirms it (`art_ready`).
    ///
    /// Throws a `ConnectionError` (`CONNECTION_LOST`) when the WebSocket
    /// can't be opened, so `initiateSocket` tries the next transport. A slow
    /// handshake is only limited by `AdkConfig.connectionTimeoutMs`, through
    /// `wait()`.
    ///
    /// Throws when authentication fails. When the server rejects the
    /// credentials (HTTP 401 or 403), or the forced token renewal of a
    /// reconnect fails, the connection fails with `AUTHENTICATION_FAILED`
    /// (emitting `authenticationFailed` and `connectionFailed`) and that
    /// `ConnectionError` is thrown, so no reconnect or fallback follows.
    public func connectWebSocket() async throws {
        let attempt: (generation: Int, credentials: AuthenticationConfig, reconnecting: Bool)? = try withSocketLock {
            if let failure = connectionFailure { throw failure }
            if isConnecting { return nil }
            isConnecting = true
            return (connectionGeneration, credentials, _isReConnecting)
        }
        guard let attempt else { return }
        let generation = attempt.generation
        let credentials = attempt.credentials

        func finish() {
            withSocketLock { if connectionGeneration == generation { isConnecting = false } }
        }

        let authData: AuthData
        do {
            let auth = try Auth.getInstance(credentials: credentials)
            authData = try await auth.authenticate(forceAuth: attempt.reconnecting)
        } catch {
            finish()
            try throwIfReplaced(generation, error)
            // Authentication is not a transport outage: rejected credentials,
            // or a forced renewal that fails while reconnecting, end the
            // reconnect cycle instead of retrying forever.
            if attempt.reconnecting || isTerminalAuthError(error) {
                throw stopAfterAuthenticationFailure(error)
            }
            throw error
        }
        if let error = replacement(of: generation) { finish(); throw error }

        var components = URLComponents(string: Constant.WS_URL)
        components?.queryItems = [
            URLQueryItem(name: "connection_id", value: withSocketLock { connection?.connectionId } ?? ""),
            URLQueryItem(name: "Org-Title",     value: credentials.orgTitle),
            URLQueryItem(name: "token",         value: authData.accessToken),
            URLQueryItem(name: "environment",   value: credentials.environment),
            URLQueryItem(name: "project-key",   value: credentials.projectKey),
        ]
        guard let wsURL = components?.url else {
            finish()
            throw ARTError.invalidPath("Could not build WebSocket URL")
        }

        await safeClose()
        if let error = replacement(of: generation) { finish(); throw error }

        let task = urlSession.webSocketTask(with: wsURL)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let started: Bool = withSocketLock {
                guard connectionGeneration == generation, connectionFailure == nil else { return false }
                websocket = task
                websocketGeneration = generation
                authorizedAccessToken = authData.accessToken
                pendingHandshake = PendingHandshake(task: task, continuation: continuation)
                return true
            }
            guard started else {
                continuation.resume(throwing: replacement(of: generation) ?? Socket.connectionCancelled())
                return
            }
            task.resume()
            startReceiveLoop(task, generation: generation)
        }
    }

    /// Ends the wait in `connectWebSocket` when `task` has opened. Does
    /// nothing when it isn't waiting, so it may be called more than once.
    private func webSocketDidOpen(_ task: URLSessionWebSocketTask) {
        let handshake: PendingHandshake? = withSocketLock {
            guard let handshake = pendingHandshake, handshake.task === task else { return nil }
            pendingHandshake = nil
            isConnecting = false
            return handshake
        }
        guard let handshake else { return }
        emitter.emit("open", NSNull())
        handshake.continuation.resume()
    }

    // MARK: - safeClose
    /// Detaches the current WebSocket first, so its closure is not reported
    /// as a dropped connection, then closes it.
    private func safeClose(timeout: Double = 1.0) async {
        let task: URLSessionWebSocketTask? = withSocketLock {
            let task = websocket
            websocket = nil
            return task
        }
        await close(task, timeout: timeout)
    }

    private func close(_ task: URLSessionWebSocketTask?, timeout: Double = 1.0) async {
        guard let task, task.state != .completed else { return }
        task.cancel(with: .normalClosure, reason: nil)
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
    }

    // MARK: - connectSSE
    private func connectSSE() async throws {
        let (generation, credentials) = withSocketLock { (connectionGeneration, self.credentials) }
        let authData: AuthData
        do {
            authData = try await Auth.getInstance(credentials: credentials).authenticate()
        } catch {
            try throwIfReplaced(generation, error)
            if isTerminalAuthError(error) {
                throw stopAfterAuthenticationFailure(error)
            }
            throw error
        }
        if let error = replacement(of: generation) { throw error }

        var components = URLComponents(string: Constant.SSE_URL)!
        components.queryItems = [
            URLQueryItem(name: "Org-Title",   value: credentials.orgTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)),
            URLQueryItem(name: "token",       value: authData.accessToken),
            URLQueryItem(name: "environment", value: credentials.environment.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)),
            URLQueryItem(name: "project-key", value: credentials.projectKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)),
        ]
        guard let sseURL = components.url else { throw ARTError.invalidPath("Bad SSE URL") }

        let streamId = UUID()
        let previous: Task<Void, Never>? = withSocketLock {
            let previous = sseTask
            sseStreamId = streamId
            return previous
        }
        previous?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            var failure: Error?
            do {
                try await self.readEventStream(sseURL, streamId: streamId, generation: generation)
            } catch {
                failure = error
            }
            self.handleEventStreamEnded(streamId, generation: generation, error: failure)
        }
        let kept: Bool = withSocketLock {
            guard sseStreamId == streamId else { return false }
            sseTask = task
            return true
        }
        if !kept { task.cancel() }
    }

    /// Reads the event stream until it ends. Only unnamed events are
    /// messages; a `close` event is the server asking the client to stop.
    private func readEventStream(_ url: URL, streamId: UUID, generation: Int) async throws {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // A quiet stream is not a failed one.
        request.timeoutInterval = 3600

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ARTError.serverError("The event stream was refused (HTTP \(status)).")
        }
        guard isLiveEventStream(streamId, generation: generation) else { return }
        emitter.emit("open", NSNull())

        // Not `bytes.lines`: it skips the blank lines that end an event.
        var parser = ServerSentEventParser()
        var line: [UInt8] = []
        for try await byte in bytes {
            guard byte == UInt8(ascii: "\n") else {
                line.append(byte)
                continue
            }
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)

            guard let event = parser.feed(text) else { continue }
            guard isLiveEventStream(streamId, generation: generation) else { return }
            switch event.name {
            case "message":
                parseIncomingMessage(event.data)
            case "close":
                handleEventStreamCloseRequest(streamId)
                return
            default:
                break
            }
        }
    }

    private func isLiveEventStream(_ streamId: UUID, generation: Int) -> Bool {
        withSocketLock { sseStreamId == streamId && connectionGeneration == generation }
    }

    /// The server asked the client to stop: the connection stays down, with
    /// no reconnect, until something waits for it or `connect()` is called.
    private func handleEventStreamCloseRequest(_ streamId: UUID) {
        withSocketLock {
            guard sseStreamId == streamId else { return }
            sseStreamId = nil
            sseTask = nil
            _isConnectionActive = false
            connectionBound = false
        }
    }

    /// A stream that ended while it carried the connection is a dropped
    /// connection, like a closed WebSocket: `close` is emitted, from which
    /// `Adk` may reconnect. A stream that fails also reports `error`.
    private func handleEventStreamEnded(_ streamId: UUID, generation: Int, error: Error?) {
        let ended: (live: Bool, wasActive: Bool) = withSocketLock {
            guard sseStreamId == streamId, connectionGeneration == generation else { return (false, false) }
            sseStreamId = nil
            sseTask = nil
            guard _isConnectionActive, websocket == nil else { return (true, false) }
            _isConnectionActive = false
            connectionBound = false
            return (true, true)
        }
        guard ended.live else { return }
        if let error {
            // Never the raw error: its description holds the URL, and so the token.
            ArtLog.error("SSE error: \(artErrorMessage(error) ?? error.localizedDescription)")
            emitter.emit("error", error)
        }
        if ended.wasActive { emitter.emit("close", error ?? NSNull()) }
    }

    // MARK: - Local fallback connection (long-poll bootstrap)
    /// Synthesizes a local `ConnectionDetail` once the long-poll transport
    /// gets an answer, since there is no WebSocket `art_ready` handshake to
    /// bind a connection. Without this, `wait()` never resolves once the
    /// transport falls back to polling.
    ///
    /// Idempotent: a no-op once a real (or prior local) connection is
    /// active. If a later `art_ready` arrives, `handleConnectionBinding`
    /// upgrades the connection to the server-issued id.
    private func openLocalFallbackConnection() {
        let local: ConnectionDetail? = withSocketLock {
            guard connectionFailure == nil else { return nil }
            if _isConnectionActive && connection != nil { return nil }
            let detail = ConnectionDetail(
                connectionId: "local_\(Int(Date().timeIntervalSince1970 * 1000))",
                instanceId:   "instance_local",
                tenantName:   credentials.orgTitle,
                environment:  credentials.environment,
                projectKey:   credentials.projectKey
            )
            connection = detail
            connectionBound = false
            _isConnectionActive = true
            return detail
        }
        guard let local else { return }
        emitter.emit("connection", local)
        resolveWaiters()
        startHeartbeat()
    }

    // MARK: - Connection binding  (art_ready / ready)
    private func handleConnectionBinding(_ rawData: String) {
        guard let jsonData = rawData.data(using: .utf8),
              let data = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

        let bound: (ConnectionDetail, [BaseSubscription], [Interception])? = withSocketLock {
            guard connectionFailure == nil else { return nil }
            autoReconnect = true
            let detail = ConnectionDetail(
                connectionId: data["connection_id"] as? String ?? "",
                instanceId:   data["instance_id"]   as? String ?? "",
                tenantName:   credentials.orgTitle,
                environment:  credentials.environment,
                projectKey:   credentials.projectKey
            )
            connection = detail
            _isConnectionActive = true
            connectionBound = true
            _isReConnecting = false
            return (detail, Array(subscriptions.values), Array(interceptors.values))
        }
        guard let (detail, subs, intercepts) = bound else { return }

        emitter.emit("connection", detail)
        resolveWaiters()
        startHeartbeat()

        subs.forEach { $0.reconnect() }
        intercepts.forEach { $0.reconnect() }
    }

    // MARK: - IWebsocketHandler: pushForSecureLine
    public func pushForSecureLine(event: String, data: Any, listen: Bool) async throws -> Any? {
        try await wait()
        let (connId, timeoutMs) = withSocketLock { (connection?.connectionId ?? "", connectionTimeoutMs) }
        let rand   = String(Int.random(in: 0..<1_000_000), radix: 36)
        let refId  = "\(connId)_secure_\(Int(Date().timeIntervalSince1970 * 1000))_\(rand)"

        let jsonObject: Any

        if JSONSerialization.isValidJSONObject(data) {
            jsonObject = data
        } else {
            jsonObject = ["value": data]
        }

        let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject)
        let content  = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let payload: [String: Any] = [
            "from":    connId,
            "channel": "art_secure",
            "event":   event,
            "content": content,
            "ref_id":  refId
        ]

        guard let msgData = try? JSONSerialization.data(withJSONObject: payload),
              let msgStr  = String(data: msgData, encoding: .utf8) else { return nil }

        if !listen {
            try sendOrFail(msgStr)
            return nil
        }

        let key = "secure-\(refId)"
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            let timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                guard !Task.isCancelled else { return }
                self?.completeSecureRequest(key, .failure(ConnectionError(
                    "The connection did not respond in time. Please reconnect and try again.",
                    code: "CONNECTION_TIMEOUT"
                )))
            }
            // Registered before sending so a fast reply can't be missed.
            let failure: ConnectionError? = withSocketLock {
                if let failure = connectionFailure { return failure }
                secureRequests[key] = PendingSecureRequest(continuation: continuation, timer: timer)
                return nil
            }
            if let failure {
                timer.cancel()
                continuation.resume(throwing: failure)
                return
            }
            do {
                try sendOrFail(msgStr)
            } catch {
                completeSecureRequest(key, .failure(error))
            }
        }
    }

    private func completeSecureRequest(_ key: String, _ result: Result<Any?, Error>) {
        let request = withSocketLock { secureRequests.removeValue(forKey: key) }
        guard let request else { return }
        request.timer.cancel()
        request.continuation.resume(with: result)
    }

    /// Sends `message`; a failed send ends the connection.
    private func sendOrFail(_ message: String) throws {
        do {
            try sendMessage(message)
        } catch {
            failConnection(
                error as? ConnectionError
                    ?? ConnectionError("The connection was lost.", code: "CONNECTION_LOST")
            )
            throw error
        }
    }

    // MARK: - IWebsocketHandler: ensureAuthorization
    public func ensureAuthorization() async throws {
        try await wait()
        // Before the server confirms the connection there is nothing to
        // renew: the socket was just opened with the current token. The
        // first call after `art_ready` renews the authorisation if the token
        // changed since.
        let (bound, running) = withSocketLock { (connectionBound, authorizationRefresh) }
        guard bound else { return }
        if let running { return try await running.value }

        let auth: Auth
        let accessToken: String
        do {
            auth = try sessionAuth()
            accessToken = try await auth.authenticate().accessToken
        } catch {
            throw stopAfterAuthenticationFailure(error)
        }
        let (failure, authorized) = withSocketLock { (connectionFailure, authorizedAccessToken) }
        if let failure { throw failure }
        if accessToken == authorized { return }

        let credentials = auth.getCredentials()
        let task: Task<Void, Error> = withSocketLock {
            if let running = authorizationRefresh { return running }
            let started = Task { try await self.refreshAuthorizationLease(accessToken, credentials) }
            authorizationRefresh = started
            return started
        }
        do {
            try await task.value
            withSocketLock { if authorizationRefresh == task { authorizationRefresh = nil } }
        } catch {
            withSocketLock { if authorizationRefresh == task { authorizationRefresh = nil } }
            throw error
        }
    }

    /// Tells the server to authorise this connection with `accessToken`.
    private func refreshAuthorizationLease(_ accessToken: String, _ creds: AuthenticationConfig) async throws {
        let (connectionId, timeoutMs) = withSocketLock { (connection?.connectionId ?? "", connectionTimeoutMs) }
        guard !connectionId.isEmpty else { throw ARTError.notConnected }
        guard let url = URL(string: "\(Constant.BASE_URL)/v1/push-message") else {
            throw ARTError.invalidPath("Malformed authorization URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        request.setValue("application/json",      forHTTPHeaderField: "Accept")
        request.setValue(creds.orgTitle,          forHTTPHeaderField: "X-Org")
        request.setValue(creds.environment,       forHTTPHeaderField: "Environment")
        request.setValue(creds.projectKey,        forHTTPHeaderField: "ProjectKey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "channel": "art_secure",
            "event": "authorization-refresh",
            "content": "{}",
            "connection_id": connectionId,
            "to": [String](),
        ] as [String: Any])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await artData(for: request, timeoutMs: timeoutMs) {
                ConnectionError(
                    "Connection authorization timed out. Please reconnect.",
                    code: "CONNECTION_AUTHORIZATION_FAILED"
                )
            }
        } catch let error as ConnectionError {
            throw error
        } catch {
            throw ConnectionError(
                "Connection authorization failed: \(error.localizedDescription)",
                code: "CONNECTION_AUTHORIZATION_FAILED"
            )
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let message = (body as? [String: Any])?["message"] as? String ?? ""
            let error = AuthHttpError(
                message.isEmpty ? "HTTP \(http.statusCode)" : message,
                status: http.statusCode,
                body: body
            )
            if error.isTerminal { stopAfterAuthenticationFailure(error) }
            throw error
        }
        withSocketLock { authorizedAccessToken = accessToken }
    }

    /// Stops the connection after the credentials were rejected or could
    /// not be renewed: fails it with `AUTHENTICATION_FAILED` and emits
    /// `authenticationFailed`. Returns the `ConnectionError` to throw.
    @discardableResult
    private func stopAfterAuthenticationFailure(_ error: Error) -> ConnectionError {
        let rejection = error as? AuthHttpError
        let failure = ConnectionError(
            artErrorMessage(error) ?? "Authentication failed. Please sign in again.",
            code: "AUTHENTICATION_FAILED",
            status: rejection?.status
        )
        failConnection(failure)
        emitter.emit("authenticationFailed", AuthenticationFailedDetail(
            status: rejection?.isTerminal == true ? rejection?.status ?? 0 : 0,
            error: artErrorMessage(error) ?? error.localizedDescription
        ))
        return withSocketLock { connectionFailure } ?? failure
    }

    /// The token manager of the running session, recreated from the
    /// socket's credentials if the app reset it.
    private func sessionAuth() throws -> Auth {
        if let auth = try? Auth.getInstance() { return auth }
        return try Auth.getInstance(credentials: withSocketLock { credentials })
    }

    // MARK: - IWebsocketHandler: removeSubscription
    public func removeSubscription(channel: String) {
        _ = withSocketLock { subscriptions.removeValue(forKey: channel) }
    }


    // MARK: - Subscribe
    /// Subscribes to `channel`, reusing an existing subscription.
    ///
    /// Throws the `ConnectionError` when the connection fails or a reply
    /// does not arrive in time.
    public func subscribe(channel: String) async throws -> BaseSubscription {
        return try await handleSubscription(channel: channel)
    }


    private func handleSubscription(channel: String) async throws -> BaseSubscription {
        try await wait()
        try await ensureAuthorization()
        let connectionId = withSocketLock { connection?.connectionId ?? "" }

        let existing = withSocketLock { subscriptions[channel] }

        if let existing = existing {
            try await existing.subscribe()
            return existing
        }

        let channelConfig = try await validateSubscription(channelName: channel, process: "subscribe")
        guard let config = channelConfig else {
            throw ARTError.channelNotFound(channel)
        }

        let subscription: BaseSubscription
        if config.channelType == "shared-object" {
            subscription = LiveObjSubscription(
                connectionID: connectionId, channelConfig: config,
                websocketHandler: self, process: "subscribe"
            )
        } else {
            subscription = Subscription(
                connectionID: connectionId, channelConfig: config,
                websocketHandler: self, process: "subscribe"
            )
        }
        // Register and replay frames that arrived before the subscription
        // existed, in one locked step: later frames are routed to the same
        // ordered queue, so arrival order is preserved.
        withSocketLock {
            subscriptions[channel] = subscription
            if let buffered = pendingIncomingMessages.removeValue(forKey: channel) {
                for item in buffered {
                    subscription.enqueue(event: item.event, payload: item.payload)
                }
            }
        }

        return subscription
    }

    private func validateSubscription(channelName: String, process: String) async throws -> ChannelConfig? {
        // Reserved channels are handled locally.
        if BaseSubscription.reservedChannels.contains(channelName) {
            return ChannelConfig(channelName: channelName, channelNamespace: "",
                                 channelType: "default", presenceUsers: [], snapshot: nil, subscriptionID: "")
        }
        return try await subscribe_to_channel(channel: channelName, process: process, websocketHandler: self)
    }

    // MARK: - IWebsocketHandler: getConnection
    public func getConnection() -> ConnectionDetail? { withSocketLock { connection } }

    // MARK: - Intercept
    public func intercept(
        interceptor: String,
        fn: @escaping ([String: Any], @escaping (Any) -> Void, @escaping (String) -> Void) -> Void
    ) async throws -> Interception {
        try await wait()

        let existing = withSocketLock { interceptors[interceptor] }
        if let existing = existing { return existing }

        let interception = Interception(interceptor: interceptor, fn: fn, websocketHandler: self)
        try await interception.validateInterception()
        withSocketLock { interceptors[interceptor] = interception }
        return interception
    }


    // MARK: - Message parsing
    private func parseIncomingMessage(_ message: String) {
        guard let data = message.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return }

        if let array = parsed as? [[String: Any]] {
            processIncomingMessages(array)
        } else if let dict = parsed as? [String: Any] {
            handleIncomingMessage(dict)
        }
    }



    private func processIncomingMessages(_ messages: [Any]) {
        messages.compactMap { $0 as? [String: Any] }.forEach { handleIncomingMessage($0) }
    }


    private func handleIncomingMessage(_ parsed: [String: Any]) {
        // A channel-less frame is normally dropped by the empty-channel guard
        // below; the limit block further down must inspect it first for a
        // billing / concurrency rejection, so extract non-optionally here.
        let channel      = parsed["channel"]         as? String ?? ""

        let event        = parsed["event"]           as? String ?? ""
        let refId        = parsed["ref_id"]          as? String ?? ""
        let returnFlag   = parsed["return_flag"]     as? String ?? ""
        let interceptorName = parsed["interceptor_name"] as? String
        let namespace    = parsed["namespace"]       as? String ?? ""
        let rawData      = parsed["content"]

        // art_ready → connection binding
        if channel == "art_ready" && event == "ready" {
            handleConnectionBinding(rawData as? String ?? "")
            return
        }

        // art_secure → reply to a control request
        if channel == "art_secure" {
            var data: Any = NSNull()
            if let inner = rawData as? [String: Any] {
                data = inner
            } else if let dataStr = rawData as? String,
                      let jsonData = dataStr.data(using: .utf8),
                      let inner = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                data = inner
            }
            completeSecureRequest("secure-\(refId)", .success([
                "data": data, "channel": channel, "namespace": namespace, "ref_id": refId, "event": event,
            ]))
            return
        }

        // Limit block — a billing / concurrency-limit rejection arrives with no
        // channel, carrying only `code` + `error`. Surface it as `limitExceeded`
        // and end the connection, so the Adk layer stops reconnecting and
        // active runs end, then drop the frame.
        if channel.isEmpty {
            let code = parsed["code"] as? String ?? ""
            if code == "CONNECTION_MINUTES_LIMIT_EXCEEDED" || code == "CONCURRENT_LIMIT_EXCEEDED" {
                let errText = parsed["error"] as? String ?? ""
                let label = code == "CONCURRENT_LIMIT_EXCEEDED"
                    ? "Concurrent connection limit reached"
                    : "Connection minutes limit exceeded"
                ArtLog.error("[ART] \(label). Reconnection blocked.")
                emitter.emit("limitExceeded", ["code": code, "error": errText])
                failConnection(ConnectionError(
                    errText.isEmpty ? "Your connection limit has been reached." : errText,
                    code: code
                ))
                return
            }
        }

        if channel.isEmpty || (event.isEmpty && returnFlag != "SA") {
            return
        }

        if event == "shift_to_http" { switchToHttpPoll(); return }

        // Build mutable payload with data field
        var payload = parsed
        payload.removeValue(forKey: "content")
        payload["data"] = rawData

        if event == "error" {
            ArtLog.error("Received error message: \(parsed)")
        }

        // Interceptor routing
        if let iName = interceptorName, !iName.isEmpty {
            let interception = withSocketLock { interceptors[iName] }
            if let interception = interception {
                Task { await interception.handleMessage(channel: channel, data: payload) }
            } else {
                ArtLog.warn("No Interception found for channel: \(channel)")
            }
            return
        }

        // Subscription routing — the subscription's ordered queue keeps
        // frames in arrival order; unknown channels are buffered until
        // `subscribe` registers them.
        var subKey = channel
        if !namespace.isEmpty { subKey += ":\(namespace)" }

        withSocketLock {
            if let sub = subscriptions[subKey] {
                sub.enqueue(event: event, payload: payload)
            } else {
                pendingIncomingMessages[subKey, default: []].append((event: event, payload: payload))
            }
        }
    }


    // MARK: - HTTP poll switch
    private func switchToHttpPoll() {
        let connectionId: String?? = withSocketLock {
            guard pullSource != "http" else { return nil }
            pullSource = "http"; pushSource = "http"
            return .some(connection?.connectionId)
        }
        guard let connectionId else { return }
        lpClient.start(connectionId: connectionId ?? "")
    }

    // MARK: - IWebsocketHandler: sendMessage
    @discardableResult
    public func sendMessage(_ message: String) throws -> Bool {
        let (failure, task) = withSocketLock { (connectionFailure, websocket) }
        if let failure { throw failure }
        // Never queue a message for silent replay after a reconnect: it may
        // start an execution twice.
        guard let task, task.state == .running else {
            throw ConnectionError(
                "The connection was lost before the message could be sent. Please reconnect.",
                code: "CONNECTION_LOST"
            )
        }
        task.send(.string(message)) { [weak self] error in
            if let error { self?.emitter.emit("error", error) }
        }
        return true
    }

    // MARK: - AutoReconnect
    public func setAutoReconnect(_ flag: Bool) { withSocketLock { autoReconnect = flag } }

    // MARK: - closeWebSocket
    /// Tears down the current transport. The connection state is reset
    /// before the socket itself is closed. With `clearConnection` the
    /// subscription and interceptor registries, and any buffered frames,
    /// are discarded too.
    public func closeWebSocket(clearConnection: Bool = false) async {
        let teardown: Teardown = withSocketLock {
            connection = nil
            if clearConnection {
                pendingIncomingMessages.removeAll()
                subscriptions.removeAll()
                interceptors.removeAll()
            }
            return takeTransportLocked()
        }
        stop(Teardown(websocket: nil, sse: teardown.sse, heartbeat: teardown.heartbeat, handshake: nil))
        teardown.handshake?.continuation.resume(throwing: Socket.connectionCancelled())
        await close(teardown.websocket)
    }


    // MARK: - IWebsocketHandler: wait
    public func wait() async throws {
        let (failure, active) = withSocketLock { (connectionFailure, _isConnectionActive) }
        if let failure { throw failure }
        if active { return }
        try Task.checkCancellation()

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let registered: (generation: Int, timeoutMs: Int)? = withSocketLock {
                    if connectionFailure != nil || _isConnectionActive { return nil }
                    connectionWaiters[id] = ConnectionWaiter(continuation: continuation, timer: nil)
                    return (connectionGeneration, connectionTimeoutMs)
                }
                guard let registered else {
                    let failure = withSocketLock { connectionFailure }
                    if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
                    return
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(registered.timeoutMs) * 1_000_000)
                    guard !Task.isCancelled else { return }
                    self?.waitTimedOut(id, generation: registered.generation)
                }
                let attached: Bool = withSocketLock {
                    guard connectionWaiters[id] != nil else { return false }
                    connectionWaiters[id]?.timer = timer
                    return true
                }
                if !attached { timer.cancel() }
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    private func waitTimedOut(_ id: UUID, generation: Int) {
        let error = ConnectionError(
            "Unable to establish a connection. Please check your connection and try again.",
            code: "CONNECTION_TIMEOUT"
        )
        if withSocketLock({ connectionGeneration == generation }) {
            failConnection(error)
        } else {
            // A newer attempt started meanwhile: give up on this wait only.
            let waiter = withSocketLock { connectionWaiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: error)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        let waiter = withSocketLock { connectionWaiters.removeValue(forKey: id) }
        waiter?.timer?.cancel()
        waiter?.continuation.resume(throwing: CancellationError())
    }

    func runHeartbeatPayload() -> [String: Any] {
        // Copy under the socket lock, read subscription state outside it
        // (lock order is subscription → socket, never the reverse).
        let (snapshot, connectionId) = withSocketLock { (Array(subscriptions), connection?.connectionId) }
        let subs = snapshot.map { (k, v) -> [String: Any] in
            ["name": k, "presenceTracking": v.isListening]
        }
        return [
            "connectionId": connectionId.map { $0 as Any } ?? NSNull(),
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "subscriptions": subs,
        ]
    }


    // MARK: - Heartbeat
    private func startHeartbeat() {
        withSocketLock {
            guard heartbeatTask == nil else { return }
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 s
                    guard let self, self.isConnectionActive else { continue }
                    let payload = self.runHeartbeatPayload()
                    // A failed heartbeat surfaces through `connectionFailed`.
                    _ = try? await self.pushForSecureLine(event: "heartbeat", data: payload, listen: false)
                }
            }
        }
    }


    private func resolveWaiters() {
        let waiters: [ConnectionWaiter] = withSocketLock {
            let waiters = Array(connectionWaiters.values)
            connectionWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.timer?.cancel()
            waiter.continuation.resume()
        }
    }


    // MARK: - IWebsocketHandler: encrypt / decrypt
    public func encrypt(_ data: String, recipientPublicKey: String) async throws -> String {
        return try await encrypt(data, recipientPublicKey)
    }
    public func decrypt(_ encryptedHash: String, senderPublicKey: String) async throws -> String {
        return try await decrypt(encryptedHash, senderPublicKey)
    }


    // MARK: - Receive loop
    /// Reads `task` until it closes. Once `task` is no longer the live
    /// transport of `generation` (replaced, closed or failed), its frames
    /// and its closure are ignored.
    private func startReceiveLoop(_ task: URLSessionWebSocketTask, generation: Int) {
        Task { [weak self] in
            while true {
                do {
                    let msg = try await task.receive()
                    guard let self, self.isLiveTransport(task, generation: generation) else { return }
                    // A frame proves the socket is open, so `open` always
                    // comes before the frames it carries.
                    self.webSocketDidOpen(task)
                    switch msg {
                    case .string(let s):
                        self.parseIncomingMessage(s)
                    case .data(let d):
                        if let s = String(data: d, encoding: .utf8) { self.parseIncomingMessage(s) }
                    @unknown default: break
                    }
                } catch {
                    self?.handleTransportClosed(task, reason: error)
                    return
                }
            }
        }
    }

    private func isLiveTransport(_ task: URLSessionWebSocketTask, generation: Int) -> Bool {
        withSocketLock { websocket === task && connectionGeneration == generation }
    }

    /// Marks the connection closed when `task` is still the live transport
    /// and emits `close`, from which `Adk` may reconnect. When `task` never
    /// opened, `connectWebSocket` throws.
    private func handleTransportClosed(_ task: URLSessionWebSocketTask, reason: Any) {
        let (isLive, handshake): (Bool, PendingHandshake?) = withSocketLock {
            let handshake = pendingHandshake?.task === task ? pendingHandshake : nil
            if handshake != nil { pendingHandshake = nil }
            guard websocket === task, websocketGeneration == connectionGeneration else { return (false, handshake) }
            websocket = nil
            _isConnectionActive = false
            isConnecting = false
            connectionBound = false
            return (true, handshake)
        }
        if isLive { emitter.emit("close", reason) }
        // Never the raw error: its description holds the URL, and so the token.
        let detail = (reason as? Error)?.localizedDescription ?? "the connection closed"
        handshake?.continuation.resume(throwing: ConnectionError(
            "The WebSocket connection could not be opened: \(detail)",
            code: "CONNECTION_LOST"
        ))
    }


//    public func getState() -> String {
//        if !isConnectionActive { return "stopped" }
//        return "connected"
//    }

    // MARK: - Event listeners
    /// Registers `handler` for `event`: `connection` (`ConnectionDetail`),
    /// `open`, `close`, `error`, `limitExceeded`, `authenticationFailed`
    /// (`AuthenticationFailedDetail`) or `connectionFailed`
    /// (`ConnectionError`).
    @discardableResult
    public func on(_ event: String, handler: @escaping (Any) -> Void) -> UUID {
        return emitter.on(event, handler: handler)
    }
    public func off(_ event: String, id: UUID) { emitter.off(event, id: id) }
}

// MARK: - URLSessionWebSocketDelegate
extension Socket: URLSessionWebSocketDelegate {
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        webSocketDidOpen(webSocketTask)
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        handleTransportClosed(webSocketTask, reason: closeCode)
    }
}

// MARK: - Server-sent events
/// Splits a `text/event-stream` into events: lines accumulate until a blank
/// line ends the event.
struct ServerSentEventParser {
    private var name = ""
    private var dataLines: [String] = []

    /// Feeds one line, without its line ending. Returns the event a blank
    /// line completes (`message` when it is unnamed); an event without data
    /// is dropped.
    mutating func feed(_ line: String) -> (name: String, data: String)? {
        if line.isEmpty {
            defer {
                name = ""
                dataLines = []
            }
            guard !dataLines.isEmpty else { return nil }
            return (name.isEmpty ? "message" : name, dataLines.joined(separator: "\n"))
        }
        let field = line.prefix { $0 != ":" }
        var value = line.dropFirst(field.count + 1)
        if value.first == " " { value.removeFirst() }
        switch field {
        case "event": name = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }
}
