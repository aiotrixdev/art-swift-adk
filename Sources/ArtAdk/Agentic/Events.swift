// Sources/ArtAdk/Agentic/Events.swift
//
// Typed event envelopes emitted on the `agent_com_<agentId>` channel.
//
// The wire shape is `{ event: String, content: Object }` produced by the
// agentbuilder backend. The backend's canonical discriminator is
// `content.type` — the top-level wire `event` is now `user_input` for
// every agent reply, so it can no longer be used. `parseAgentEvent`
// normalises every recognised envelope's `event` to one of `agentEvents`;
// anything else is forwarded as `UnknownAgentEvent`.
//

import Foundation

// MARK: - Canonical event types

/// The known event types emitted on agent communication channels.
///
/// Any envelope whose normalised type falls outside this list is
/// forwarded as an `.unknown` payload.
public let agentEvents: [String] = [
    "agent_general_response",
    "agent_error_response",
    "human_input_request",
    "agent_wait_response",
    "planner_correction_request",
]

/// Returns `true` if `name` is a recognised agent event type.
public func isKnownAgentEvent(_ name: String) -> Bool {
    agentEvents.contains(name)
}

// MARK: - Number coercion helper

/// JSON numbers decoded by `JSONSerialization` arrive as `NSNumber`;
/// normalise any numeric representation to `Double`.
private func adkDouble(_ value: Any?) -> Double? {
    switch value {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    default: return nil
    }
}

// MARK: - EnvelopeMeta

/// Routing / correlation fields injected into every egress `content` body
/// by `_content_with_meta` on the server. May be empty strings when the
/// upstream task lacked them.
public protocol EnvelopeMeta {
    /// The server-issued thread id this event belongs to.
    var threadId: String { get }
    /// The server-generated reference id for this event.
    var refId: String { get }
    /// The agent id that emitted this event.
    var agentId: String { get }
    /// `ref_id` of the request this message is responding to.
    var replyTo: String { get }
}

// MARK: - AgentOutput

/// Successful terminal response from an agent run.
public struct AgentOutput: EnvelopeMeta {
    /// Discriminator: always `agent_general_response`.
    public var type: String { "agent_general_response" }
    /// Status: always `final_response`.
    public var status: String { "final_response" }

    /// The terminal natural-language message returned by the agent.
    public let message: String
    /// Optional structured payload returned alongside `message`.
    public let data: [String: Any]?
    /// Optional metadata bag (model name, token usage, etc.).
    public let metadata: [String: Any]?

    public let threadId: String
    public let refId: String
    public let agentId: String
    public let replyTo: String

    public init(from m: [String: Any]) {
        message = m["message"] as? String ?? ""
        data = m["data"] as? [String: Any]
        metadata = m["metadata"] as? [String: Any]
        threadId = m["thread_id"] as? String ?? ""
        refId = m["ref_id"] as? String ?? ""
        agentId = m["agent_id"] as? String ?? ""
        replyTo = m["reply_to"] as? String ?? ""
    }
}

// MARK: - AgentError

/// Error response from an agent run; terminal for the originating `Run`.
///
/// Conforms to `Error` so a `Run` can surface it through `done()`.
public struct AgentError: EnvelopeMeta, Error, LocalizedError {
    /// Discriminator: always `agent_error_response`.
    public var type: String { "agent_error_response" }
    /// Status: always `error`.
    public var status: String { "error" }

    /// Framework or agent-supplied error code.
    public let code: String
    /// Human-readable description of the failure.
    public let message: String
    /// Optional structured details bag.
    public let details: [String: Any]?

    public let threadId: String
    public let refId: String
    public let agentId: String
    public let replyTo: String

    public init(from m: [String: Any]) {
        code = m["code"] as? String ?? ""
        message = m["message"] as? String ?? ""
        details = m["details"] as? [String: Any]
        threadId = m["thread_id"] as? String ?? ""
        refId = m["ref_id"] as? String ?? ""
        agentId = m["agent_id"] as? String ?? ""
        replyTo = m["reply_to"] as? String ?? ""
    }

    /// Designated initialiser for SDK-synthesised errors (HITL timeout,
    /// transport failure) that do not originate from a wire payload.
    public init(
        code: String,
        message: String,
        details: [String: Any]? = nil,
        threadId: String = "",
        refId: String = "",
        agentId: String = "",
        replyTo: String = ""
    ) {
        self.code = code
        self.message = message
        self.details = details
        self.threadId = threadId
        self.refId = refId
        self.agentId = agentId
        self.replyTo = replyTo
    }

    public var errorDescription: String? { "AgentError(\(code)): \(message)" }
}

// MARK: - ExpectedResponseType

/// Modality the agent expects a human to respond with.
///
/// `text` is the only value the server currently emits; the other cases
/// document the intended modalities for client renderers.
public enum ExpectedResponseType: String {
    case text
    case choice
    case confirm
    case file
    case structured

    /// Parses a raw `expected_response_type` string, falling back to
    /// `.text` for unknown values.
    public static func parse(_ raw: String?) -> ExpectedResponseType {
        guard let raw, let value = ExpectedResponseType(rawValue: raw) else {
            return .text
        }
        return value
    }
}

// MARK: - HumanInputRequest

/// An interactive prompt the agent is awaiting a human reply on.
public struct HumanInputRequest: EnvelopeMeta {
    /// Discriminator: always `human_input_request`.
    public var type: String { "human_input_request" }
    /// Status: always `awaiting_input`.
    public var status: String { "awaiting_input" }

    /// The question to present to the user.
    public let prompt: String
    /// Optional context bag passed alongside the prompt.
    public let context: [String: Any]?
    /// Parsed expected modality (falls back to `.text`).
    public let expectedResponseType: ExpectedResponseType
    /// The raw `expected_response_type` string as received, preserved
    /// verbatim so callers can interpret unknown future modalities.
    public let expectedResponseTypeRaw: String
    /// Optional client-side timeout in seconds. The `Run` enforces it and
    /// rejects with a `HUMAN_INPUT_TIMEOUT` `AgentError` on expiry.
    public let timeout: Double?
    /// Optional JSON schema when `expectedResponseType` is `.structured`.
    public let schema: Any?

    public let threadId: String
    public let refId: String
    public let agentId: String
    public let replyTo: String

    public init(from m: [String: Any]) {
        let raw = m["expected_response_type"] as? String ?? "text"
        prompt = m["prompt"] as? String ?? ""
        context = m["context"] as? [String: Any]
        expectedResponseType = ExpectedResponseType.parse(raw)
        expectedResponseTypeRaw = raw
        timeout = adkDouble(m["timeout"])
        schema = m["schema"]
        threadId = m["thread_id"] as? String ?? ""
        refId = m["ref_id"] as? String ?? ""
        agentId = m["agent_id"] as? String ?? ""
        replyTo = m["reply_to"] as? String ?? ""
    }
}

// MARK: - AgentWait

/// Notification that the agent is awaiting another agent's response.
public struct AgentWait: EnvelopeMeta {
    /// Discriminator: always `agent_wait_response`.
    public var type: String { "agent_wait_response" }
    /// Status: always `waiting_for_agent`.
    public var status: String { "waiting_for_agent" }

    /// Id of the agent we are waiting on.
    public let waitingForAgentId: String
    /// Optional invocation id for the downstream agent call.
    public let invocationId: String?
    /// Optional reason string describing what the agent is waiting for.
    public let reason: String?
    /// Optional timeout in seconds.
    public let timeout: Double?
    /// Optional progress / status payload.
    public let progress: [String: Any]?

    public let threadId: String
    public let refId: String
    public let agentId: String
    public let replyTo: String

    public init(from m: [String: Any]) {
        waitingForAgentId = m["waiting_for_agent_id"] as? String ?? ""
        invocationId = m["invocation_id"] as? String
        reason = m["reason"] as? String
        timeout = adkDouble(m["timeout"])
        progress = m["progress"] as? [String: Any]
        threadId = m["thread_id"] as? String ?? ""
        refId = m["ref_id"] as? String ?? ""
        agentId = m["agent_id"] as? String ?? ""
        replyTo = m["reply_to"] as? String ?? ""
    }
}

// MARK: - PlannerCorrection

/// Server-initiated request that the planner correct its course of action.
public struct PlannerCorrection: EnvelopeMeta {
    /// Discriminator: always `planner_correction_request`.
    public var type: String { "planner_correction_request" }

    /// Whether the planner is being asked to correct (`true`) or merely
    /// being notified (`false`).
    public let correctionRequired: Bool
    /// Server-provided explanation for the correction.
    public let reason: String
    /// Optional new goal proposed by the server.
    public let newGoal: String?
    /// Optional list of agent ids suggested for the corrected plan.
    public let suggestedAgents: [String]?

    public let threadId: String
    public let refId: String
    public let agentId: String
    public let replyTo: String

    public init(from m: [String: Any]) {
        correctionRequired = m["correction_required"] as? Bool ?? false
        reason = m["reason"] as? String ?? ""
        newGoal = m["new_goal"] as? String
        if let agents = m["suggested_agents"] as? [Any] {
            suggestedAgents = agents.map { "\($0)" }
        } else {
            suggestedAgents = nil
        }
        threadId = m["thread_id"] as? String ?? ""
        refId = m["ref_id"] as? String ?? ""
        agentId = m["agent_id"] as? String ?? ""
        replyTo = m["reply_to"] as? String ?? ""
    }
}

// MARK: - UnknownAgentEvent

/// Catch-all payload when the server emits an event the SDK does not yet
/// model. The raw `content` map is preserved verbatim.
public struct UnknownAgentEvent {
    /// The raw wire event name.
    public let event: String
    /// The raw `content` map as delivered by the server.
    public let content: [String: Any]

    public init(event: String, content: [String: Any]) {
        self.event = event
        self.content = content
    }
}

// MARK: - AgentEvent (discriminated payload)

/// The typed payload carried by an `AgentEventEnvelope`.
///
/// Swift-idiomatic replacement for the Dart `Object content` field: an
/// enum with associated values gives exhaustive, type-safe switching at
/// the call site.
public enum AgentEvent {
    case output(AgentOutput)
    case error(AgentError)
    case humanInput(HumanInputRequest)
    case wait(AgentWait)
    case plannerCorrection(PlannerCorrection)
    case unknown(UnknownAgentEvent)
}

// MARK: - AgentEventEnvelope

/// Discriminated envelope wrapping any inbound agent event.
public struct AgentEventEnvelope {
    /// The normalised canonical event type — one of `agentEvents` when
    /// known, otherwise the raw wire event name.
    public let event: String
    /// The typed payload.
    public let payload: AgentEvent

    public init(event: String, payload: AgentEvent) {
        self.event = event
        self.payload = payload
    }

    /// Whether `payload` is one of the typed (non-`.unknown`) variants.
    public var isKnown: Bool { isKnownAgentEvent(event) }
}

/// Callback fired for every event delivered to a thread.
public typealias AgentUserListener = (AgentEventEnvelope) -> Void

// MARK: - parseAgentEvent

/// Resolves the variant map inside a raw `content` payload.
///
/// Two shapes occur depending on how `Subscription` decoded the wire
/// frame: the variant map may sit at the top level (`raw["type"]`), or be
/// nested one level deeper (`raw["content"]["type"]`) when the whole
/// envelope was passed through verbatim. Mirrors the `_resolveInnerContent`
/// fix on the Flutter controller.
private func resolveAgentContent(_ raw: [String: Any]) -> [String: Any] {
    if raw["type"] is String { return raw }
    if let nested = raw["content"] as? [String: Any], nested["type"] is String {
        return nested
    }
    return raw
}

/// Parses a raw `{ event, content }` envelope into a typed
/// `AgentEventEnvelope`.
///
/// Discrimination is by `content.type` — the backend's canonical type
/// field. The top-level wire `event` is now `user_input` for every agent
/// reply, so it is only used as a legacy fallback (older builds sent the
/// type as the top-level `event`, e.g. `agent_output` / `agent_error`).
/// The returned envelope's `event` is always normalised to the new
/// canonical type so downstream switches only need one set of names.
/// Unrecognised types produce an `.unknown` payload carrying the raw wire
/// event name (so transport-level frames like `error` / `transport_error`
/// still flow through `AgentThread`).
public func parseAgentEvent(_ raw: [String: Any]) -> AgentEventEnvelope {
    let wireEvent = raw["event"] as? String ?? ""
    let outerContent = (raw["content"] as? [String: Any]) ?? raw
    let contentMap = resolveAgentContent(outerContent)

    let rawType = contentMap["type"] as? String ?? ""
    let type = rawType.isEmpty ? wireEvent : rawType

    switch type {
    case "agent_general_response", "agent_output":
        return AgentEventEnvelope(
            event: "agent_general_response",
            payload: .output(AgentOutput(from: contentMap))
        )
    case "agent_error_response", "agent_error":
        return AgentEventEnvelope(
            event: "agent_error_response",
            payload: .error(AgentError(from: contentMap))
        )
    case "human_input_request":
        return AgentEventEnvelope(
            event: "human_input_request",
            payload: .humanInput(HumanInputRequest(from: contentMap))
        )
    case "agent_wait_response", "agent_wait":
        return AgentEventEnvelope(
            event: "agent_wait_response",
            payload: .wait(AgentWait(from: contentMap))
        )
    case "planner_correction_request", "planner_correction":
        return AgentEventEnvelope(
            event: "planner_correction_request",
            payload: .plannerCorrection(PlannerCorrection(from: contentMap))
        )
    default:
        return AgentEventEnvelope(
            event: wireEvent,
            payload: .unknown(UnknownAgentEvent(event: wireEvent, content: contentMap))
        )
    }
}
