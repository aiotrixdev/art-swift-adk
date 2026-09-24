// Sources/ArtAdk/Agentic/Orchestrator.swift
//
// Top-level handle for an orchestrator-managed workflow.

import Foundation

/// Top-level handle for an orchestrator-managed workflow.
///
/// Each `Orchestrator` subscribes to its dedicated `orch_com_<id>` channel
/// and spawns `OrchestratorThread`s on it without requiring the
/// channel-level `orchestratorEnabled` flag — the act of calling
/// `adk.orchestrator(_:)` is itself the opt-in.
///
/// Typical use:
///
/// ```swift
/// let orch = adk.orchestrator("my-orchestrator")
/// let thread = try await orch.thread()
/// thread.listen { data in print("event: \(data["event"] ?? "")") }
/// try await thread.push(event: "user_input",
///                       data: ["goal": "kick off the workflow"])
/// ```
public final class Orchestrator: BaseWorkflow {

    /// The server-side identifier for this orchestrator. Used to compute
    /// the channel name `orch_com_<orchestratorId>`.
    public let orchestratorId: String

    /// Creates an `Orchestrator` bound to `socket`.
    public init(_ orchestratorId: String, socket: Socket) {
        self.orchestratorId = orchestratorId
        super.init(socket: socket)
    }

    public override var channelName: String { "orch_com_\(orchestratorId)" }

    /// Returns an `OrchestratorThread` for this orchestrator.
    ///
    /// Awaits the lazy subscription on first call. When `threadId` is
    /// supplied and matches a live thread it is reused; otherwise a fresh
    /// thread is created.
    ///
    /// Unlike `Subscription.thread(...)` this method **bypasses** the
    /// `channelConfig.orchestratorEnabled` gate because the orchestrator
    /// channel is, by construction, an orchestrator workflow.
    public func thread(threadId: String? = nil) async throws -> OrchestratorThread {
        let sub = try await getSubscription()
        return sub.threadUnchecked(threadId: threadId)
    }

    // MARK: - Storage (orchestrator-scoped)

    /// Uploads a local file scoped to this orchestrator
    /// (`config_id` = `orchestratorId`).
    @discardableResult
    public func upload(fileURL: URL, options: UploadOptions = UploadOptions()) async throws -> FileRef {
        var opts = options
        opts.configId = orchestratorId
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
        var opts = options
        opts.configId = orchestratorId
        return try await Storage().upload(data: data, filename: filename, contentType: contentType, options: opts)
    }

    /// Lists files scoped to this orchestrator.
    public func listFiles(options: ListOptions = ListOptions()) async throws -> StorageFileList {
        var opts = options
        opts.configId = orchestratorId
        return try await Storage().listFiles(options: opts)
    }
}
