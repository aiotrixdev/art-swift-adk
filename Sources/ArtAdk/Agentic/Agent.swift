// Sources/ArtAdk/Agentic/Agent.swift
//
// Handle for talking to a single named agent over its
// `agent_com_<agentId>` channel. Subscription lifecycle lives on
// `BaseWorkflow`; this type only declares the channel name and the
// `thread()` factory.

import Foundation

/// Handle for a single named agent.
///
/// Subscription is lazy and idempotent — multiple `thread()` calls share
/// one underlying subscription, established on first need.
///
/// Typical use:
///
/// ```swift
/// let agent = try adk.agent("my-agent")
/// let thread = agent.thread()
/// await thread.listen { event in print("event: \(event.event)") }
/// let run = try await thread.run("plan my trip")
/// let output = try await run.done()
/// ```
public final class Agent: BaseWorkflow {

    /// The agent's slug, optionally with `@buildname`. Used to compute the
    /// channel name `agent_com_<agentId>`.
    public let agentId: String

    /// Creates an `Agent` bound to `socket`.
    ///
    /// `agentId` is the agent's slug, optionally pinned to a named build
    /// (`my-agent@release2`). Throws `ARTError.invalidArgument` for anything
    /// else; see `validateExecutionReference(_:)`.
    public init(_ agentId: String, socket: Socket) throws {
        try validateExecutionReference(agentId)
        self.agentId = agentId
        super.init(socket: socket)
    }

    public override var channelName: String { "agent_com_\(agentId)" }

    public func thread(_ threadId: String? = nil) -> AgentThread {
        AgentThread(agent: self, threadId: threadId)
    }

    /// Calls `listener` when the connection fails, so `AgentThread` can end
    /// its active run. Returns an id for `offConnectionFailure(_:)`.
    @discardableResult
    func onConnectionFailure(_ listener: @escaping (ConnectionError) -> Void) -> UUID {
        socket.onConnectionFailure(listener)
    }

    /// Removes a listener added with `onConnectionFailure(_:)`.
    func offConnectionFailure(_ id: UUID) {
        socket.offConnectionFailure(id)
    }

    // MARK: - Storage (agent-scoped)

    /// Uploads a local file owned by this agent's channel configuration,
    /// whatever `options.configId` contains. `options.threadId` is required;
    /// `AgentThread.upload` sets it.
    @discardableResult
    public func upload(fileURL: URL, options: UploadOptions = UploadOptions()) async throws -> FileRef {
        var opts = options
        opts.configId = try await getSubscription().configurationId
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
        opts.configId = try await getSubscription().configurationId
        return try await Storage().upload(data: data, filename: filename, contentType: contentType, options: opts)
    }

    /// Lists the files this agent's channel configuration can access in
    /// `options.threadId` (required; `AgentThread.listFiles` sets it).
    public func listFiles(options: ListOptions = ListOptions()) async throws -> StorageFileList {
        var opts = options
        opts.configId = try await getSubscription().configurationId
        return try await Storage().listFiles(options: opts)
    }
}
