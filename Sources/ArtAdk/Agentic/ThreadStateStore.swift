// Sources/ArtAdk/Agentic/ThreadStateStore.swift
//
// Holds one thread's current `ThreadState` and its `listenState`
// callbacks. Shared by `AgentThread` (sequence-checked) and
// `OrchestratorThread` (no sequence check).

import Foundation

final class ThreadStateStore {

    let threadId: String
    private let enforcesSequence: Bool
    private let lock = ArtLock()
    private var current: ThreadState
    private var listeners: [(id: UUID, callback: (ThreadState) -> Void)] = []

    init(threadId: String, enforcesSequence: Bool) {
        self.threadId = threadId
        self.enforcesSequence = enforcesSequence
        self.current = ThreadState(
            threadId: threadId, phase: .idle, source: .client,
            message: "Ready", occurredAt: ArtEncoding.isoTimestamp()
        )
    }

    /// Snapshot of the current state.
    var state: ThreadState { lock.sync { current } }

    var hasListeners: Bool { lock.sync { !listeners.isEmpty } }

    @discardableResult
    func addListener(_ callback: @escaping (ThreadState) -> Void) -> UUID {
        let id = UUID()
        lock.sync { listeners.append((id: id, callback: callback)) }
        return id
    }

    func removeListener(_ id: UUID) {
        lock.sync { listeners.removeAll { $0.id == id } }
    }

    func removeAllListeners() {
        lock.sync { listeners.removeAll() }
    }

    /// Applies a state, ignoring states for other threads and (for agent
    /// threads) states older than the current `sequence`. Listeners are
    /// notified outside the lock.
    func apply(_ incoming: ThreadState) {
        let result = lock.sync { () -> (ThreadState, [(ThreadState) -> Void])? in
            if !incoming.threadId.isEmpty && incoming.threadId != threadId { return nil }
            var next = incoming
            next.threadId = threadId
            if enforcesSequence {
                let previous = current.sequence ?? -1
                let sequence = incoming.sequence ?? previous + 1
                if sequence < previous { return nil }
                next.sequence = sequence
            }
            current = next
            return (next, listeners.map { $0.callback })
        }
        guard let result else { return }
        result.1.forEach { $0(result.0) }
    }

    /// Records a client-side transition.
    func transition(
        _ phase: ThreadStatePhase,
        _ source: ThreadStateSource,
        _ message: String,
        reason: String? = nil,
        workspaceId: String? = nil,
        agentId: String? = nil
    ) {
        apply(ThreadState(
            threadId: threadId, phase: phase, source: source, message: message,
            reason: reason, workspaceId: workspaceId, agentId: agentId,
            occurredAt: ArtEncoding.isoTimestamp()
        ))
    }
}
