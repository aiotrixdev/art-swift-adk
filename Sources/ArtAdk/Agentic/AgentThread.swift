// Sources/ArtAdk/Agentic/AgentThread.swift
//
// A single conversation thread within an `Agent`. Mirrors
// `js-adk-common/agentic/agentThread.ts` and the Flutter
// `lib/src/agentic/agent_thread.dart`.

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
public final class AgentThread {

    /// The owning agent.
    public let agent: Agent

    /// Stable identifier carried in every outbound message's content as
    /// `thread_id`, so the server can correlate inbound replies back to
    /// this thread.
    public let threadId: String

    private var masterListenerTask: Task<Void, Never>?
    private var userListeners: [AgentUserListener] = []
    private var feedbackHandlers: [AgentHumanInputHandler] = []
    private var activeRun: Run?

    /// Created via `Agent.thread()`; not for direct instantiation.
    init(agent: Agent,threadId: String? = nil) {
        self.agent = agent
        self.threadId = threadId ?? AgentThread.generateThreadId()
    }

    private static func generateThreadId() -> String {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let rand = String(UInt32.random(in: 0 ..< UInt32.max), radix: 36)
        return "thread_\(ts)_\(rand)"
    }

    /// Subscribes `callback` to every typed event delivered to this thread.
    ///
    /// Multiple callbacks may be registered; each receives every event.
    /// The first call also installs the underlying subscription listener.
    public func listen(_ callback: @escaping AgentUserListener) async {
        await ensureMasterListener()
        userListeners.append(callback)
    }

    /// Subscribes `callback` to inbound `trace` diagnostic / telemetry frames
    /// (heartbeats, checkpoints, deadlock signals) on this thread. Each frame
    /// is delivered as its raw value. Mirrors js-adk-common
    /// `AgentThread.listenTrace`.
    public func listenTrace(_ callback: @escaping (Any) -> Void) async {
        guard let sub = try? await agent.getSubscription() else { return }
        sub.bind(event: "trace", callback: callback)
        sub.attachThreadBind(threadId, "trace", callback)
    }

    /// Registers a handler invoked whenever a `HumanInputRequest` arrives
    /// for the currently active `Run`.
    public func feedbackRequest(_ handler: @escaping AgentHumanInputHandler) {
        feedbackHandlers.append(handler)
    }

    /// Starts a new `Run` on this thread.
    ///
    /// Returns a `Run` whose `done()` resolves with the terminal
    /// `AgentOutput` or throws the `AgentError`. When `replyId` is set, the
    /// outbound event becomes `user_reply` (carrying `reply_id`) rather
    /// than `user_input`. If a previous run is still active it is
    /// force-closed — each thread may only have one active run at a time.
    @discardableResult
    public func run(_ userInput: Any, replyId: String? = nil) async throws -> Run {
        await ensureMasterListener()

        if let previous = activeRun, !previous.isClosed {
            previous.close("Superseded by new run on the same thread")
        }

        let run = Run(self)
        activeRun = run

        let sub = try await agent.getSubscription()
        let event = (replyId != nil) ? "user_reply" : "user_input"
        var content: [String: Any] = [
            "user_input": userInput,
            "thread_id": threadId,
        ]
        if let replyId {
            content["reply_id"] = replyId
        }

        let refId = try await sub.push(event: event, data: content)
        run.setRefId(refId ?? "")
        return run
    }

    // MARK: - Internal (called by Run)

    /// Invoked by `Run` when a `human_input_request` arrives.
    func fireRequestFeedback(_ req: HumanInputRequest, _ run: Run) {
        for handler in feedbackHandlers {
            handler(req, run)
        }
    }

    /// Clears the active run reference on a terminal event.
    func closeRun(_ run: Run) {
        if activeRun === run { activeRun = nil }
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
        let refId = try await sub.push(event: "user_reply", data: content)
        return refId ?? ""
    }

    // MARK: - Dispatch

    private func ensureMasterListener() async {
        if let task = masterListenerTask {
            await task.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            if let sub = try? await self.agent.getSubscription() {
                sub.listen { [weak self] raw in
                    self?.dispatch(raw)
                }
            }
        }
        masterListenerTask = task
        await task.value
    }

    private func dispatch(_ raw: [String: Any]) {
        var envelope = parseAgentEvent(raw)

        // Surface wire-level transport errors as a typed
        // `agent_error_response` so the active Run rejects and listeners
        // get a normalised envelope.
        if envelope.event == "error" || envelope.event == "transport_error" {
            var message = "WebSocket error"
            if case let .unknown(unknown) = envelope.payload {
                message = (unknown.content["message"] as? String)
                    ?? (unknown.content["error"] as? String)
                    ?? message
            }
            let err = AgentError(
                code: "TRANSPORT_ERROR",
                message: message,
                details: nil,
                threadId: threadId,
                refId: "",
                agentId: agent.agentId,
                replyTo: ""
            )
            envelope = AgentEventEnvelope(
                event: "agent_error_response",
                payload: .error(err)
            )
        }

        if let activeRun {
            activeRun.push(envelope)
        }

        for callback in userListeners {
            callback(envelope)
        }
    }
}
