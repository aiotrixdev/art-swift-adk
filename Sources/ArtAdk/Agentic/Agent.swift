// Sources/ArtAdk/Agentic/Agent.swift
//
// Handle for talking to a single named agent over its
// `agent_com_<agentId>` channel. Subscription lifecycle lives on
// `BaseWorkflow`; this type only declares the channel name and the
// `thread()` factory. Mirrors `js-adk-common/agentic/agent.ts` and the
// Flutter `lib/src/agentic/agent.dart`.

import Foundation

/// Handle for a single named agent.
///
/// Subscription is lazy and idempotent — multiple `thread()` calls share
/// one underlying subscription, established on first need.
///
/// Typical use:
///
/// ```swift
/// let agent = adk.agent("my-agent")
/// let thread = agent.thread()
/// await thread.listen { event in print("event: \(event.event)") }
/// let run = try await thread.run("plan my trip")
/// let output = try await run.done()
/// ```
public final class Agent: BaseWorkflow {

    /// The server-side identifier for the agent. Used to compute the
    /// channel name `agent_com_<agentId>`.
    public let agentId: String

    /// Creates an `Agent` bound to `socket`.
    public init(_ agentId: String, socket: Socket) {
        self.agentId = agentId
        super.init(socket: socket)
    }

    public override var channelName: String { "agent_com_\(agentId)" }

    /// Returns a new `AgentThread` backed by this agent.
    ///
    /// Each call returns a fresh thread with its own thread id; the same
    /// agent may host many concurrent threads.
    public func thread() -> AgentThread {
        AgentThread(agent: self)
    }
}
