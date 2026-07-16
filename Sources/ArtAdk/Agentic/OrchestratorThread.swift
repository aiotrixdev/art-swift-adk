// Sources/ArtAdk/Agentic/OrchestratorThread.swift
//
// Per-thread handle for orchestrator-enabled channels. Wraps a
// `Subscription` and scopes every push and listen call to a single logical
// thread within the channel. Mirrors
// `js-adk-common/agentic/orcThread.ts` and the Flutter
// `lib/src/agentic/orchestrator_thread.dart`.

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

    private var attachedEvents: Set<String> = []
    private var disposed = false

    /// Created via `Subscription.thread(...)`. When `threadId` is omitted a
    /// new id is generated locally.
    init(_ subscription: Subscription, _ threadId: String? = nil) {
        self.subscription = subscription
        self.threadId = threadId ?? OrchestratorThread.generateThreadId()
    }

    private static func generateThreadId() -> String {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let rand = String(UInt32.random(in: 0 ..< UInt32.max), radix: 36)
        return "thread_\(ts)_\(rand)"
    }

    /// Whether `dispose()` has been called.
    public var isDisposed: Bool { disposed }

    /// Returns `threadId`. Provided for parity with the JS SDK.
    public func getId() -> String { threadId }

    /// Sends a message tagged with this thread's `threadId`.
    ///
    /// Any caller-supplied `options` are merged with `threadID: threadId` —
    /// the thread id always wins to prevent cross-thread leakage.
    public func push(
        event: String,
        data: [String: Any],
        options: PushConfig? = nil
    ) async throws {
        guard !disposed else {
            throw ARTError.serverError("OrchestratorThread \(threadId) has been disposed")
        }
        let merged = PushConfig(to: options?.to ?? [], threadID: threadId)
        try await subscription.push(event: event, data: data, options: merged)
    }

    /// Drains buffered events for this thread and subscribes `callback` to
    /// every future event tagged with `threadId`. Each invocation receives
    /// a map with `event` and `content` keys.
    public func listen(_ callback: @escaping ([String: Any]) -> Void) {
        guard !disposed else { return }
        subscription.attachThreadListener(threadId, callback)
        attachedEvents.insert("all")
    }

    /// Subscribes `callback` to a single named `event` within this thread.
    public func bind(event: String, callback: @escaping (Any) -> Void) {
        guard !disposed else { return }
        subscription.attachThreadBind(threadId, event, callback)
        attachedEvents.insert(event)
    }

    /// Subscribes `callback` to inbound `trace` diagnostic / telemetry frames
    /// on this thread. Binds both the channel-level and thread-scoped `trace`
    /// event so a frame is delivered whether or not it carries a `thread_id`.
    /// Mirrors js-adk-common `OrchestratorThread.listenTrace`.
    public func listenTrace(_ callback: @escaping (Any) -> Void) {
        guard !disposed else { return }
        subscription.bind(event: "trace", callback: callback)
        subscription.attachThreadBind(threadId, "trace", callback)
        attachedEvents.insert("trace")
    }

    /// Removes every listener bound to `event` on this thread.
    public func remove(event: String) {
        guard !disposed else { return }
        subscription.detachThreadListener(threadId, event)
        attachedEvents.remove(event)
    }

    /// Detaches all listeners attached through this thread and unregisters
    /// the thread from its parent subscription. Idempotent.
    public func dispose() {
        guard !disposed else { return }
        disposed = true
        let hadTrace = attachedEvents.contains("trace")
        for event in attachedEvents {
            subscription.detachThreadListener(threadId, event)
        }
        // `listenTrace` also binds a channel-level `trace` listener; the loop
        // above only detaches the thread-scoped one, so clear it too.
        if hadTrace {
            subscription.remove(event: "trace")
        }
        attachedEvents.removeAll()
        subscription.unregisterThread(threadId)
    }
}
