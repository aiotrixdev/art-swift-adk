// Sources/ArtAdk/Agentic/OrchestratorThread.swift
//
// Per-thread handle for orchestrator-enabled channels. Wraps a
// `Subscription` and scopes every push and listen call to a single logical
// thread within the channel.

import Foundation

/// Per-thread handle for orchestrator-enabled channels.
///
/// Threads are first-class on the wire — every outbound payload carries a
/// `thread_id` and every listener observes only events tagged with the
/// matching id. Created via `Subscription.thread(...)` /
/// `Orchestrator.thread(...)`. Calling `dispose()` detaches every attached
/// listener and unregisters the thread from its parent subscription.
public final class OrchestratorThread {

    private let subscription: Subscription

    /// Stable identifier for this thread. Carried as `thread_id` on every
    /// outbound message and used to namespace inbound events.
    public let threadId: String

    private let lock = ArtLock()
    private var attachedEvents: Set<String> = []
    /// Channel-level `trace` listeners added by `listenTrace`, removed
    /// individually on `dispose()` so other threads keep theirs.
    private var traceTokens: [UUID] = []
    private var stateBindToken: UUID?
    private var disposed = false
    private let stateStore: ThreadStateStore

    /// Created via `Subscription.thread(...)`. When `threadId` is omitted a
    /// new id is generated locally.
    init(_ subscription: Subscription, _ threadId: String? = nil) {
        self.subscription = subscription
        self.threadId = threadId ?? AgentThread.generateThreadId()
        self.stateStore = ThreadStateStore(threadId: self.threadId, enforcesSequence: false)
    }

    /// Whether `dispose()` has been called.
    public var isDisposed: Bool { lock.sync { disposed } }

    /// Returns `threadId`.
    public func getId() -> String { threadId }

    private func guardActive(_ operation: String) -> Bool {
        if isDisposed {
            ArtLog.warn("OrchestratorThread \(threadId) has been disposed; ignoring \(operation)")
            return false
        }
        return true
    }

    private func ensureActive() throws {
        if isDisposed {
            throw ARTError.serverError("OrchestratorThread \(threadId) has been disposed")
        }
    }

    /// Sends a message tagged with this thread's `threadId`.
    ///
    /// Caller `options` (`to`, `fileMeta`) are kept; `threadID` is always
    /// this thread's id to prevent cross-thread leakage. Records a
    /// `submitted` state.
    public func push(
        event: String,
        data: [String: Any],
        options: PushConfig? = nil
    ) async throws {
        try ensureActive()
        var merged = options ?? PushConfig()
        merged.threadID = threadId
        stateStore.transition(.submitted, .client, "Request submitted")
        try await subscription.push(event: event, data: data, options: merged)
    }

    // MARK: - Storage (thread-scoped)

    /// Uploads a local file scoped to this thread (`config_id` = threadId).
    @discardableResult
    public func upload(fileURL: URL, options: UploadOptions = UploadOptions()) async throws -> FileRef {
        try ensureActive()
        var opts = options
        opts.configId = threadId
        return try await Storage().upload(fileURL: fileURL, options: opts)
    }

    /// In-memory variant of `upload(fileURL:options:)`.
    @discardableResult
    public func upload(
        data: Data,
        filename: String? = nil,
        contentType: String? = nil,
        options: UploadOptions = UploadOptions()
    ) async throws -> FileRef {
        try ensureActive()
        var opts = options
        opts.configId = threadId
        return try await Storage().upload(data: data, filename: filename, contentType: contentType, options: opts)
    }

    /// Lists files scoped to this thread.
    public func listFiles(options: ListOptions = ListOptions()) async throws -> StorageFileList {
        try ensureActive()
        var opts = options
        opts.configId = threadId
        return try await Storage().listFiles(options: opts)
    }

    // MARK: - Listeners

    /// Drains buffered events for this thread and subscribes `callback` to
    /// every future event tagged with `threadId`. Each invocation receives
    /// a map with `event` and `content` keys.
    public func listen(_ callback: @escaping ([String: Any]) -> Void) {
        guard guardActive("listen") else { return }
        subscription.attachThreadListener(threadId, callback)
        lock.sync { _ = attachedEvents.insert("all") }
    }

    /// Subscribes `callback` to a single named `event` within this thread.
    public func bind(event: String, callback: @escaping (Any) -> Void) {
        guard guardActive("bind") else { return }
        subscription.attachThreadBind(threadId, event, callback)
        lock.sync { _ = attachedEvents.insert(event) }
    }

    /// Subscribes `callback` to inbound `trace` diagnostic / telemetry frames
    /// on this thread. Binds both the channel-level and thread-scoped `trace`
    /// event so a frame is delivered whether or not it carries a `thread_id`.
    @available(*, deprecated, message: "Use listenState(_:emitCurrent:) for operational UI. Trace is reserved for diagnostics.")
    public func listenTrace(_ callback: @escaping (Any) -> Void) {
        guard guardActive("listenTrace") else { return }
        let token = subscription.bind(event: "trace", callback: callback)
        subscription.attachThreadBind(threadId, "trace", callback)
        lock.sync {
            traceTokens.append(token)
            _ = attachedEvents.insert("trace")
        }
    }

    /// Subscribes `callback` to this thread's operational state: `submitted`
    /// on `push`, then server `thread_state` events for this thread. When
    /// `emitCurrent` is `true` the current state is delivered immediately.
    /// Returns a closure that removes the callback.
    @discardableResult
    public func listenState(
        _ callback: @escaping (ThreadState) -> Void,
        emitCurrent: Bool = true
    ) -> () -> Void {
        guard guardActive("listenState") else { return {} }

        // One thread-scoped `thread_state` binding feeds every state
        // callback (binding once per callback would apply each event
        // several times).
        let needsBinding: Bool = lock.sync {
            guard stateBindToken == nil else { return false }
            stateBindToken = UUID() // reserve
            return true
        }
        if needsBinding {
            let token = subscription.attachThreadBind(threadId, "thread_state") { [weak self] content in
                guard let self, let dict = content as? [String: Any] else { return }
                self.stateStore.apply(ThreadState(from: dict))
            }
            lock.sync {
                stateBindToken = token
                _ = attachedEvents.insert("thread_state")
            }
        }

        let id = stateStore.addListener(callback)
        if emitCurrent { callback(stateStore.state) }

        return { [weak self] in
            guard let self else { return }
            self.stateStore.removeListener(id)
            guard !self.stateStore.hasListeners else { return }
            let token: UUID? = self.lock.sync {
                let token = self.stateBindToken
                self.stateBindToken = nil
                self.attachedEvents.remove("thread_state")
                return token
            }
            if let token, !self.isDisposed {
                self.subscription.detachThreadListener(self.threadId, "thread_state", id: token)
            }
        }
    }

    /// The thread's current operational state.
    public func getState() -> ThreadState {
        stateStore.state
    }

    /// Removes every listener bound to `event` on this thread.
    public func remove(event: String) {
        guard !isDisposed else { return }
        subscription.detachThreadListener(threadId, event)
        lock.sync { _ = attachedEvents.remove(event) }
    }

    /// Detaches all listeners attached through this thread and unregisters
    /// the thread from its parent subscription. Idempotent.
    public func dispose() {
        let snapshot: (events: Set<String>, traceTokens: [UUID])? = lock.sync {
            guard !disposed else { return nil }
            disposed = true
            let events = attachedEvents
            let tokens = traceTokens
            attachedEvents.removeAll()
            traceTokens.removeAll()
            stateBindToken = nil
            return (events, tokens)
        }
        guard let snapshot else { return }

        for event in snapshot.events {
            subscription.detachThreadListener(threadId, event)
        }
        // `listenTrace` also bound channel-level `trace` listeners; remove
        // only this thread's, leaving other threads' trace listeners intact.
        for token in snapshot.traceTokens {
            subscription.remove(event: "trace", id: token)
        }
        stateStore.removeAllListeners()
        subscription.unregisterThread(threadId)
    }
}
