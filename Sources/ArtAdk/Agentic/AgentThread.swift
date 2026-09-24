// Sources/ArtAdk/Agentic/AgentThread.swift
//
// A single conversation thread within an `Agent`.

import Foundation

/// Callback fired when the agent emits a `HumanInputRequest` for the
/// currently active `Run`. The handler collects input from the user and
/// calls `run.sendFeedback(_:)` to continue.
public typealias AgentHumanInputHandler = (HumanInputRequest, Run) -> Void

/// A single conversation thread within an `Agent`.
///
/// Holds a list of `listen` callbacks and a list of `feedbackRequest`
/// handlers; dispatches events from the agent's channel through both. At
/// most one `Run` is active at a time — starting a new run while a
/// previous one is still in flight force-closes the previous run.
///
/// Outbound messages carry a top-level `thread_id`, and replies tagged
/// with this thread's id are routed back to it (as well as untagged
/// channel events).
public final class AgentThread {

    /// The owning agent.
    public let agent: Agent

    /// Stable identifier carried as `thread_id` on every outbound message
    /// (top level and inside `content`), so the server can correlate
    /// replies back to this thread.
    public let threadId: String

    private let lock = ArtLock()
    private var masterListenerTask: Task<Bool, Never>?
    private var userListeners: [AgentUserListener] = []
    private var feedbackHandlers: [AgentHumanInputHandler] = []
    private var activeRun: Run?
    private let stateStore: ThreadStateStore

    /// Created via `Agent.thread()`; not for direct instantiation.
    init(agent: Agent, threadId: String? = nil) {
        self.agent = agent
        self.threadId = threadId ?? AgentThread.generateThreadId()
        self.stateStore = ThreadStateStore(threadId: self.threadId, enforcesSequence: true)
    }

    /// A random lowercase UUID.
    static func generateThreadId() -> String {
        UUID().uuidString.lowercased()
    }

    /// Subscribes `callback` to every typed event delivered to this thread.
    ///
    /// Multiple callbacks may be registered; each receives every event.
    /// The first call also installs the underlying subscription listeners.
    public func listen(_ callback: @escaping AgentUserListener) async {
        await ensureMasterListener()
        lock.sync { userListeners.append(callback) }
    }

    /// Subscribes `callback` to this thread's operational state (submitted,
    /// waiting for approval / another agent / a workspace, completed,
    /// failed, and server `thread_state` updates). When `emitCurrent` is
    /// `true` the current state is delivered immediately. Returns a closure
    /// that removes the callback.
    @discardableResult
    public func listenState(
        _ callback: @escaping (ThreadState) -> Void,
        emitCurrent: Bool = true
    ) async -> () -> Void {
        await ensureMasterListener()
        let id = stateStore.addListener(callback)
        if emitCurrent { callback(stateStore.state) }
        return { [weak self] in self?.stateStore.removeListener(id) }
    }

    /// The thread's current operational state.
    public func getState() -> ThreadState {
        stateStore.state
    }

    /// Subscribes `callback` to inbound `trace` diagnostic / telemetry frames
    /// (heartbeats, checkpoints, deadlock signals) on this thread. Each frame
    /// is delivered as its raw value.
    @available(*, deprecated, message: "Use listenState(_:emitCurrent:) for operational UI. Trace is reserved for diagnostics.")
    public func listenTrace(_ callback: @escaping (Any) -> Void) async {
        guard let sub = try? await agent.getSubscription() else { return }
        sub.bind(event: "trace", callback: callback)
        sub.attachThreadBind(threadId, "trace", callback)
    }

    /// Registers a handler invoked whenever a `HumanInputRequest` arrives
    /// for the currently active `Run`.
    public func feedbackRequest(_ handler: @escaping AgentHumanInputHandler) {
        lock.sync { feedbackHandlers.append(handler) }
    }

    /// Starts a new `Run` on this thread.
    ///
    /// Returns a `Run` whose `done()` resolves with the terminal
    /// `AgentOutput` or throws the `AgentError`. When `replyId` is set, the
    /// outbound event becomes `user_reply` (carrying `reply_id`) rather
    /// than `user_input`. If a previous run is still active it is
    /// force-closed — each thread may only have one active run at a time.
    ///
    /// - Parameters:
    ///   - userInput: the message for the agent, usually a `String`.
    ///   - replyId: the `ref_id` of the agent message this input answers.
    ///   - fileMeta: uploaded files the agent may use, sent as the
    ///     frame's `file_meta`. Upload first,
    ///     e.g. `FileMeta(try await agent.upload(fileURL: url))`.
    @discardableResult
    public func run(_ userInput: Any, replyId: String? = nil, fileMeta: [FileMeta] = []) async throws -> Run {
        await ensureMasterListener()

        let run = Run(self)
        let previous: Run? = lock.sync {
            let previous = activeRun
            activeRun = run
            return previous
        }
        if let previous, !previous.isClosed {
            ArtLog.warn("[adk] starting new run while previous run is still active — closing previous")
            previous.close("Superseded by new run on the same thread")
        }

        stateStore.transition(.submitted, .client, "Request submitted")

        let sub = try await agent.getSubscription()
        let event = (replyId != nil) ? "user_reply" : "user_input"
        var content: [String: Any] = [
            "user_input": userInput,
            "thread_id": threadId,
        ]
        if let replyId {
            content["reply_id"] = replyId
        }

        let refId = try await sub.push(
            event: event,
            data: content,
            options: PushConfig(threadID: threadId, fileMeta: fileMeta)
        )
        run.setRefId(refId ?? "")
        return run
    }

    // MARK: - Storage (thread-scoped)

    /// Uploads a local file, scoped to this thread: `configId` is always
    /// set to `threadId`, whatever `options` contains.
    @discardableResult
    public func upload(fileURL: URL, options: UploadOptions = UploadOptions()) async throws -> FileRef {
        var opts = options
        opts.configId = threadId
        return try await Storage().upload(fileURL: fileURL, options: opts)
    }

    /// Byte-based variant of `upload(fileURL:options:)`, for callers that
    /// already have the file in memory rather than on disk.
    @discardableResult
    public func upload(
        data: Data,
        filename: String? = nil,
        contentType: String? = nil,
        options: UploadOptions = UploadOptions()
    ) async throws -> FileRef {
        var opts = options
        opts.configId = threadId
        return try await Storage().upload(data: data, filename: filename, contentType: contentType, options: opts)
    }

    /// Lists files scoped to this thread's `threadId`.
    public func listFiles(options: ListOptions = ListOptions()) async throws -> StorageFileList {
        var opts = options
        opts.configId = threadId
        return try await Storage().listFiles(options: opts)
    }

    // MARK: - Internal (called by Run)

    /// Invoked by `Run` when a `human_input_request` arrives.
    func fireRequestFeedback(_ req: HumanInputRequest, _ run: Run) {
        let handlers = lock.sync { feedbackHandlers }
        for handler in handlers {
            handler(req, run)
        }
    }

    /// Clears the active run reference on a terminal event.
    func closeRun(_ run: Run) {
        lock.sync {
            if activeRun === run { activeRun = nil }
        }
    }

    /// Sends a `user_reply` carrying `replyId` for the active human-input
    /// prompt.
    @discardableResult
    func sendReply(_ value: Any, _ replyId: String) async throws -> String {
        let sub = try await agent.getSubscription()
        let content: [String: Any] = [
            "user_input": value,
            "thread_id": threadId,
            "reply_id": replyId,
        ]
        let refId = try await sub.push(
            event: "user_reply",
            data: content,
            options: PushConfig(threadID: threadId)
        )
        return refId ?? ""
    }

    // MARK: - Dispatch

    /// Installs, once, the subscription listeners that fan out to user
    /// callbacks and the active run: the channel-wide `listen` plus the
    /// thread-scoped route for frames tagged with this `thread_id`. A
    /// failed subscribe is retried on the next call.
    private func ensureMasterListener() async {
        let task: Task<Bool, Never> = lock.sync {
            if let existing = masterListenerTask { return existing }
            let started = Task { [weak self] () -> Bool in
                guard let self else { return false }
                do {
                    let sub = try await self.agent.getSubscription()
                    sub.listen { [weak self] raw in self?.dispatch(raw) }
                    sub.attachThreadListener(self.threadId) { [weak self] raw in self?.dispatch(raw) }
                    return true
                } catch {
                    ArtLog.error("[adk] agent subscription failed: \(error)")
                    return false
                }
            }
            masterListenerTask = started
            return started
        }
        if await task.value == false {
            lock.sync {
                if masterListenerTask == task { masterListenerTask = nil }
            }
        }
    }

    private func dispatch(_ raw: [String: Any]) {
        var envelope = parseAgentEvent(raw)

        // Surface wire-level transport errors as a typed
        // `agent_error_response` so the active Run rejects and listeners
        // get a normalised envelope.
        if envelope.event == "error" || envelope.event == "transport_error" {
            var message = "WebSocket error"
            var details: [String: Any]?
            if case let .unknown(unknown) = envelope.payload {
                message = (unknown.content["message"] as? String)
                    ?? (unknown.content["error"] as? String)
                    ?? message
                details = unknown.content
            }
            let err = AgentError(
                code: "TRANSPORT_ERROR",
                message: message,
                details: details,
                threadId: threadId,
                refId: "",
                agentId: agent.agentId,
                replyTo: ""
            )
            // Same fields as a server-sent `agent_error_response`.
            var content: [String: Any] = [
                "type": err.type,
                "status": err.status,
                "code": err.code,
                "message": err.message,
                "thread_id": err.threadId,
                "ref_id": err.refId,
                "agent_id": err.agentId,
                "reply_to": err.replyTo,
            ]
            if let details { content["details"] = details }
            envelope = AgentEventEnvelope(
                event: "agent_error_response",
                payload: .error(err),
                content: content
            )
        }

        if !envelope.isKnown {
            ArtLog.warn("[adk] unknown agent event \"\(envelope.event)\" — passing through untyped.")
        }

        updateState(for: envelope.payload)

        let (run, listeners) = lock.sync { (activeRun, userListeners) }

        run?.push(envelope)

        for callback in listeners {
            callback(envelope)
        }
    }

    /// Operational state transitions driven by inbound events.
    private func updateState(for payload: AgentEvent) {
        switch payload {
        case .threadState(let state):
            stateStore.apply(state)
        case .humanInput(let request):
            stateStore.transition(.waitingForApproval, .agent, "Waiting for your input", reason: request.prompt)
        case .wait(let wait):
            let workspaceId = ArtJSON.string(wait.progress?["workspace_id"])
            let waitingFor = wait.waitingForAgentId.isEmpty ? nil : wait.waitingForAgentId
            if let workspaceId {
                stateStore.transition(
                    .waitingForWorkspace, .workspace, "Waiting for workspace",
                    reason: wait.reason, workspaceId: workspaceId, agentId: waitingFor
                )
            } else {
                stateStore.transition(
                    .waitingForAgent, .agent, "Waiting for another agent",
                    reason: wait.reason, agentId: waitingFor
                )
            }
        case .output:
            stateStore.transition(.completed, .agent, "Completed")
        case .error(let error):
            stateStore.transition(.failed, .agent, "Execution failed", reason: error.message)
        case .plannerCorrection, .unknown:
            break
        }
    }
}
