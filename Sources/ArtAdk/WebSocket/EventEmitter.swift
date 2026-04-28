// Sources/ArtAdk/WebSocket/EventEmitter.swift

import Foundation

public final class EventEmitter {
    private var listeners: [String: [(id: UUID, handler: (Any) -> Void)]] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: - on / off / emit
    @discardableResult
    public func on(_ event: String, handler: @escaping (Any) -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        listeners[event, default: []].append((id: id, handler: handler))
        return id
    }

    public func off(_ event: String, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        listeners[event]?.removeAll { $0.id == id }
    }

    public func off(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        listeners.removeValue(forKey: event)
    }

    public func removeAllListeners() {
        lock.lock(); defer { lock.unlock() }
        listeners.removeAll()
    }

    public func emit(_ event: String, _ data: Any = NSNull()) {
        lock.lock()
        let handlers = listeners[event] ?? []
        lock.unlock()
        handlers.forEach { $0.handler(data) }
    }

    public func listenerCount(_ event: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return listeners[event]?.count ?? 0
    }
}
