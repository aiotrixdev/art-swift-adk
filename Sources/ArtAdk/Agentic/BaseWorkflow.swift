// Sources/ArtAdk/Agentic/BaseWorkflow.swift
//
// Abstract base for client-side workflow handles (`Agent`,
// `Orchestrator`) that own a single underlying `Subscription` to a
// dedicated server-side channel.
//
// Concentrates the lazy-idempotent subscribe pattern in one place:
// subclasses only need to override `channelName`.

import Foundation

/// Base class owning the lazy subscription to a workflow's dedicated
/// channel.
///
/// A stored-property base class (rather than a protocol) is used
/// deliberately: the subscribe-coalescing state (`subscription`,
/// `subscribeTask`) must live somewhere, and Swift protocols cannot carry
/// stored properties. Subclasses override `channelName`.
open class BaseWorkflow {

    /// Underlying socket used to (lazily) open the workflow's subscription.
    public let socket: Socket

    private let lock = ArtLock()
    private var _subscription: Subscription?

    /// In-flight subscribe task used to coalesce concurrent callers — only
    /// the first `connect()` performs the network round-trip.
    private var subscribeTask: Task<Subscription, Error>?

    public init(socket: Socket) {
        self.socket = socket
    }

    /// Live subscription, populated once the lazy subscribe completes.
    /// `nil` until `connect()` / `getSubscription()` has been awaited once.
    public var subscription: Subscription? { lock.sync { _subscription } }

    /// The dedicated server-side channel this workflow subscribes to.
    /// Subclasses MUST override.
    open var channelName: String {
        fatalError("BaseWorkflow subclasses must override `channelName`")
    }

    /// Kicks off the (lazy) subscription to `channelName` if it has not
    /// started yet, and returns `self` for chaining.
    ///
    /// Idempotent — only the first call schedules a network round-trip;
    /// subsequent calls reuse the in-flight task. A failed subscribe is not
    /// kept, so the next call tries again; its error reaches
    /// `getSubscription()` callers.
    @discardableResult
    public func connect() -> Self {
        _ = subscribeTaskStarting()
        return self
    }

    private func subscribeTaskStarting() -> Task<Subscription, Error> {
        lock.sync {
            if let running = subscribeTask { return running }
            let channel = channelName
            let sock = socket
            let token = UUID()
            let started = Task { [weak self] () throws -> Subscription in
                do {
                    let raw = try await sock.subscribe(channel: channel)
                    guard let typed = raw as? Subscription else {
                        throw ARTError.serverError(
                            "Channel \(channel) did not yield a Subscription"
                        )
                    }
                    self?.lock.sync { self?._subscription = typed }
                    return typed
                } catch {
                    self?.subscribeFailed(token)
                    throw error
                }
            }
            subscribeTask = started
            subscribeToken = token
            return started
        }
    }

    private var subscribeToken: UUID?

    private func subscribeFailed(_ token: UUID) {
        lock.sync {
            if subscribeToken == token {
                subscribeTask = nil
                subscribeToken = nil
            }
        }
    }

    /// Returns the active `Subscription`, kicking off `connect()` if it has
    /// not yet been invoked.
    ///
    /// Waits for the connection first, so it throws the `ConnectionError`
    /// once the connection has failed.
    ///
    /// Intended for use by collaborators (`AgentThread`,
    /// `Orchestrator.thread`); rarely called directly from app code.
    public func getSubscription() async throws -> Subscription {
        try await socket.wait()
        if let subscription { return subscription }
        return try await subscribeTaskStarting().value
    }
}
