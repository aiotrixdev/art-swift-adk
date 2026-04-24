// Sources/ARTSdk/WebSocket/Socket.swift


import Foundation

// MARK: - WebSocket event callbacks
public struct WebSocketEvents {
    public var onOpen:       ((URLSessionWebSocketTask.CloseCode?) -> Void)?
    public var onError:      ((Error) -> Void)?
    public var onClose:      ((URLSessionWebSocketTask.CloseCode, String?) -> Void)?
    public var onConnection: ((ConnectionDetail) -> Void)?
}

// MARK: - Socket (singleton)
public final class Socket: NSObject, IWebsocketHandler {
    private static let lock = NSLock()
    
    // MARK: Singleton
    private static var _instance: Socket?
    // MARK: - State
    private var websocket: URLSessionWebSocketTask?
    private var credentials: AuthenticationConfig = AuthenticationConfig()
    private var subscriptions: [String: BaseSubscription] = [:]
    private var interceptors:  [String: Interception]     = [:]
    private var connection: ConnectionDetail? = nil
    public var isConnectionActive: Bool = false
    private var heartbeatTask: Task<Void, Never>?
    private var pendingSendMessages: [String] = []
    private var secureCallbacks: [String: (Any) -> Void] = [:]
    private var pendingIncomingMessages: [String: [(event: String, payload: [String: Any])]] = [:]
    public var encrypt: (String, String) async throws -> String
    public var decrypt: (String, String) async throws -> String
    private var pullSource: String = "socket"  // "socket" | "sse" | "http"
    private var pushSource: String = "socket"
    private var lpClient: LongPollClient!
    private var isConnecting:      Bool = false
    internal var isReConnecting:     Bool = false
    private var autoReconnect:     Bool = false
    
    private var sseTask: Task<Void, Never>?
    private var urlSession: URLSession!
    
    // MARK: - Event emitter
    private let emitter = EventEmitter()
    
    // MARK: - Connection waiter
    private var connectionContinuations: [CheckedContinuation<Void, Never>] = []
    private let continuationLock = NSLock()
    private let socketLock = NSRecursiveLock()

    /// Thread-safe access to shared state. Wraps lock/unlock in a nonisolated
    /// synchronous context so Swift 6 doesn't warn about locks in async code.
    private nonisolated func withSocketLock<T>(_ body: () -> T) -> T {
        socketLock.lock()
        defer { socketLock.unlock() }
        return body()
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
        
        self.lpClient = LongPollClient(opts: LongPollOptions(
            endpoint: Constant.LPOLL,
            getAuthHeaders: { [weak self] in
                guard let self else { return [:] }
                let auth = try Auth.getInstance(credentials: self.credentials)
                _ = try await auth.authenticate()
                let authData = auth.getAuthData()
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
            onError: { err in
            }
        ))
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
    
    
    // MARK: - initiateSocket
    public func initiateSocket(credentials: AuthenticationConfig) async {
        guard websocket == nil || !isConnectionActive else { return }
        self.credentials = credentials
        
        // 1.  WebSocket
        do {
            try await connectWebSocket()
            pullSource = "socket"; pushSource = "socket"
            return
        } catch {
            return
        }
        
        // 2. SSE
        do {
            try await connectSSE()
            pullSource = "sse"; pushSource = "http"
            return
        } catch {
        }
        
        // 3. LongPoll
        pullSource = "http"; pushSource = "http"
        lpClient.start(connectionId: connection?.connectionId)
    }
    
    
    // MARK: - connectWebSocket
    public func connectWebSocket() async throws {
        guard !isConnecting else { return }
        isConnecting = true

        
        let auth = try Auth.getInstance(credentials: credentials)
        let authData: AuthData
        do {
            authData = try await auth.authenticate(forceAuth: isReConnecting)
        } catch {
            isConnecting = false
            emitter.emit("close", error)
            throw error
        }
        
        var components = URLComponents(string: Constant.WS_URL)!
        
        components.queryItems = [
            URLQueryItem(name: "connection_id", value: connection?.connectionId ?? ""),
            URLQueryItem(name: "Org-Title",     value: credentials.orgTitle),
            URLQueryItem(name: "token",         value: authData.accessToken),
            URLQueryItem(name: "environment",   value: credentials.environment),
            URLQueryItem(name: "project-key",   value: credentials.projectKey),
        ]
        guard let wsURL = components.url else {
            isConnecting = false
            throw ARTError.invalidPath("Could not build WebSocket URL")
        }
        

        await safeClose()
        
        // Handshake with timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)  // 5 s
                throw ARTError.timeout("WebSocket handshake timeout")
            }
            group.addTask { [weak self] in
                guard let self else { return }
                let task = self.urlSession.webSocketTask(with: wsURL)
              
                task.resume()
                self.websocket = task
                self.isConnecting = false
                self.emitter.emit("open", NSNull())
                self.startReceiveLoop()
            }
            // Cancel timeout once connect task finishes
            try await group.next()
            group.cancelAll()
        }
    }
    
    // MARK: - safeClose
    private func safeClose(timeout: Double = 1.0) async {
        guard let task = websocket else { return }
        if task.state == .completed { websocket = nil; return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.cancel(with: .normalClosure, reason: nil)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                cont.resume()
            }
        }
        websocket = nil
    }
    
    // MARK: - connectSSE
    private func connectSSE() async throws {
        let auth     = try Auth.getInstance(credentials: credentials)
        let authData = try await auth.authenticate()
        
        var components = URLComponents(string: Constant.SSE_URL)!
        components.queryItems = [
            URLQueryItem(name: "Org-Title",   value: credentials.orgTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)),
            URLQueryItem(name: "token",       value: authData.accessToken),
            URLQueryItem(name: "environment", value: credentials.environment.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)),
            URLQueryItem(name: "project-key", value: credentials.projectKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)),
        ]
        guard let sseURL = components.url else { throw ARTError.invalidPath("Bad SSE URL") }
        
        sseTask = Task { [weak self] in
            guard let self else { return }
            
            do {
                var req = URLRequest(url: sseURL)
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                
                self.isConnectionActive = true
                self.emitter.emit("open", NSNull())
                
                for try await line in bytes.lines {
                    
                    let textLine = String(line)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if textLine.hasPrefix("data:") {
                        let payload = String(textLine.dropFirst(5))
                            .trimmingCharacters(in: .whitespaces)
                        
                        self.parseIncomingMessage(payload)
                    }
                    
                    if Task.isCancelled { break }
                }
                
            } catch {
            }
        }
    }
    
    // MARK: - Connection binding  (art_ready / ready)
    private func handleConnectionBinding(_ rawData: String) {
        setAutoReconnect(true)
        guard let jsonData = rawData.data(using: .utf8),
              let data = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }
        
        connection = ConnectionDetail(
            connectionId: data["connection_id"] as? String ?? "",
            instanceId:   data["instance_id"]   as? String ?? "",
            tenantName:   credentials.orgTitle,
            environment:  credentials.environment,
            projectKey:   credentials.projectKey
        )
        
        emitter.emit("connection", connection!)
        isConnectionActive = true
        startHeartbeat()
        resolveWaiters()
        
        // Flush pending messages
        let (queued, subs, intercepts) = withSocketLock { () -> ([String], [BaseSubscription], [Interception]) in
            let q = pendingSendMessages
            pendingSendMessages = []
            return (q, Array(subscriptions.values), Array(interceptors.values))
        }

        queued.forEach { _ = sendMessage($0) }

        if autoReconnect {
            subs.forEach { $0.reconnect() }
            intercepts.forEach { $0.reconnect() }
        }
    }
    
    // MARK: - IWebsocketHandler: pushForSecureLine
    public func pushForSecureLine(event: String, data: Any, listen: Bool) async throws -> Any? {
        let connId = connection?.connectionId ?? ""
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
            _ = sendMessage(msgStr)
            return nil
        }
        
        return await withCheckedContinuation { [weak self] (cont: CheckedContinuation<Any?, Never>) in
            guard let self else { cont.resume(returning: nil); return }
            let callbackKey = "secure-\(refId)"
            self.withSocketLock {
                self.secureCallbacks[callbackKey] = { result in cont.resume(returning: result) }
            }
            _ = self.sendMessage(msgStr)

            // Timeout to prevent hanging forever if server never responds
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                guard let self else { return }
                let cb = self.withSocketLock { self.secureCallbacks.removeValue(forKey: callbackKey) }
                if cb != nil {
                    cont.resume(returning: nil)
                }
            }
        }
    }
    
    // MARK: - IWebsocketHandler: removeSubscription
    public func removeSubscription(channel: String) {
        _ = withSocketLock { subscriptions.removeValue(forKey: channel) }
    }
    
    
    // MARK: - Subscribe
    public func subscribe(channel: String) async throws -> BaseSubscription {
        return try await handleSubscription(channel: channel)
    }
    
    
    private func handleSubscription(channel: String) async throws -> BaseSubscription {
        await wait()
        let connectionId = connection?.connectionId ?? ""
        
        let existing = withSocketLock { subscriptions[channel] }

        if let existing = existing {
            await existing.subscribe()
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
        let buf = withSocketLock { () -> [(event: String, payload: [String: Any])]? in
            subscriptions[channel] = subscription
            return pendingIncomingMessages.removeValue(forKey: channel)
        }

        // Replay buffered messages
        if let buf = buf {
            for item in buf {
                await subscription.handleMessage(event: item.event, payload: item.payload)
            }
        }
        
        return subscription
    }
    
    private func validateSubscription(channelName: String, process: String) async throws -> ChannelConfig? {
        if ["art_config", "art_secure"].contains(channelName) {
            return ChannelConfig(channelName: channelName, channelNamespace: "",
                                 channelType: "default", presenceUsers: [], snapshot: nil, subscriptionID: "")
        }
        return try await subscribe_to_channel(channel: channelName, process: process, websocketHandler: self)
    }
    
    // MARK: - IWebsocketHandler: getConnection
    public func getConnection() -> ConnectionDetail? { connection }
    
    // MARK: - Intercept
    public func intercept(
        interceptor: String,
        fn: @escaping ([String: Any], @escaping (Any) -> Void, @escaping (String) -> Void) -> Void
    ) async throws -> Interception {
        await wait()
        
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
        guard let channel = parsed["channel"] as? String else {
            return
        }
        
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
        
        // art_secure → secure callback
        if channel == "art_secure" {
            let key = "secure-\(refId)"
            let cb = withSocketLock { secureCallbacks.removeValue(forKey: key) }
            if let cb = cb {
                var dataDict: [String: Any] = ["channel": channel, "namespace": namespace, "ref_id": refId, "event": event]
                if let dataStr = rawData as? String,
                   let jsonData = dataStr.data(using: .utf8),
                   let innerParsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    dataDict["data"] = innerParsed
                }
                cb(["data": dataDict["data"] as Any, "channel": channel, "namespace": namespace, "ref_id": refId, "event": event])
            }
            return
        }
        
        if channel.isEmpty || (event.isEmpty && returnFlag != "SA") {
            return
        }
        
        if event == "shift_to_http" { switchToHttpPoll(); return }
        
        // Build mutable payload with data field
        var payload = parsed
        payload.removeValue(forKey: "content")
        payload["data"] = rawData
        
        // Interceptor routing
        if let iName = interceptorName, !iName.isEmpty {
            let interception = withSocketLock { interceptors[iName] }
            if let interception = interception {
                Task { await interception.handleMessage(channel: channel, data: payload) }
            } else {
            }
            return
        }
        
        // Subscription routing
        var subKey = channel
        if !namespace.isEmpty { subKey += ":\(namespace)" }
        
        let sub = withSocketLock { subscriptions[subKey] }

        if let sub = sub {
            Task { await sub.handleMessage(event: event, payload: payload) }
        } else {
            withSocketLock { pendingIncomingMessages[subKey, default: []].append((event: event, payload: payload)) }
        }
    }
    
    
    // MARK: - HTTP poll switch
    private func switchToHttpPoll() {
        guard pullSource != "http" else { return }
        pullSource = "http"; pushSource = "http"
        lpClient.start(connectionId: connection?.connectionId ?? "")
    }
    
    // MARK: - IWebsocketHandler: sendMessage
    @discardableResult
    public func sendMessage(_ message: String) -> Bool {
 
        guard let task = websocket, task.state == .running else {
            withSocketLock { pendingSendMessages.append(message) }
            return false
        }
        task.send(.string(message)) { [weak self] error in
            if let error { self?.emitter.emit("error", error) }
        }
        return true
    }
    
    // MARK: - AutoReconnect
    public func setAutoReconnect(_ flag: Bool) { autoReconnect = flag }
    
    // MARK: - closeWebSocket
    public func closeWebSocket(clearConnection: Bool = false) async {
        await safeClose()
        isConnectionActive = false
        connection         = nil
        isConnecting       = false
        sseTask?.cancel(); sseTask = nil
        
        if clearConnection {
            withSocketLock {
                pendingIncomingMessages.removeAll()
                pendingSendMessages.removeAll()
                subscriptions.removeAll()
                interceptors.removeAll()
            }
        }
        
        heartbeatTask?.cancel(); heartbeatTask = nil
    }
    
    
    // MARK: - IWebsocketHandler: wait
    public func wait() async {
        if isConnectionActive { return }
        await withCheckedContinuation { [weak self] (cont: CheckedContinuation<Void, Never>) in
            guard let self else { cont.resume(); return }
            continuationLock.lock()
            connectionContinuations.append(cont)
            continuationLock.unlock()
        }
    }
    
    private func runHeartbeatPayload() -> [String: Any] {
        let subs = withSocketLock {
            subscriptions.map { (k, v) -> [String: Any] in
                ["name": k, "presenceTracking": v.isListening]
            }
        }
        return ["connectionId": connection?.connectionId as Any, "timestamp": Date().timeIntervalSince1970 * 1000, "subscriptions": subs]
    }
    
    
    // MARK: - Heartbeat
    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 s
                guard let self, self.isConnectionActive else { continue }
                let payload = self.runHeartbeatPayload()
                _ = try? await self.pushForSecureLine(event: "heartbeat", data: payload, listen: false)
            }
        }
    }
    
    
    private func resolveWaiters() {
        continuationLock.lock()
        let conts = connectionContinuations
        connectionContinuations = []
        continuationLock.unlock()
        conts.forEach { $0.resume() }
    }
    
    
    // MARK: - IWebsocketHandler: encrypt / decrypt
    public func encrypt(_ data: String, recipientPublicKey: String) async throws -> String {
        return try await encrypt(data, recipientPublicKey)
    }
    public func decrypt(_ encryptedHash: String, senderPublicKey: String) async throws -> String {
        return try await decrypt(encryptedHash, senderPublicKey)
    }
    
    
    // MARK: - Receive loop
    private func startReceiveLoop() {
        Task { [weak self] in
            guard let self else { return }
            while let task = websocket, task.state == .running {
                do {
                    let msg = try await task.receive()
                    switch msg {
                    case .string(let s):
                        parseIncomingMessage(s)
                    case .data(let d):
                        if let s = String(data: d, encoding: .utf8) { parseIncomingMessage(s) }
                    @unknown default: break
                    }
                } catch {
                    isConnectionActive = false
                    isConnecting = false
                    emitter.emit("close", error)
                    break
                }
            }
        }
    }
    

//    public func getState() -> String {
//        if !isConnectionActive { return "stopped" }
//        return "connected"
//    }
    
    // MARK: - Event listeners (mirrors adk.ts on/off)
    @discardableResult
    public func on(_ event: String, handler: @escaping (Any) -> Void) -> UUID {
        return emitter.on(event, handler: handler)
    }
    public func off(_ event: String, id: UUID) { emitter.off(event, id: id) }
}

// MARK: - URLSessionWebSocketDelegate
extension Socket: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol_: String?) {
        isConnectionActive = false  // wait for art_ready event
    }
    
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        isConnectionActive = false
        isConnecting = false
        
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) }

        emitter.emit("close", closeCode)
    }
}
