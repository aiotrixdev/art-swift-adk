// Sources/ArtAdk/Agentic/BaseWorkflow.swift
//
// Abstract base for client-side workflow handles (`Agent`,
// `Orchestrator`) that own a single underlying `Subscription` to a
// dedicated server-side channel.
//
// Concentrates the lazy-idempotent subscribe pattern in one place:
// subclasses only need to override `channelName`. Mirrors
// `js-adk-common/agentic/BaseWorkflow.ts` and the Flutter
// `lib/src/agentic/base_workflow.dart`.

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

    /// Live subscription, populated once the lazy subscribe completes.
    /// `nil` until `connect()` / `getSubscription()` has been awaited once.
    public private(set) var subscription: Subscription?

    /// In-flight subscribe task used to coalesce concurrent callers — only
    /// the first `connect()` performs the network round-trip.
    private var subscribeTask: Task<Subscription, Error>?

    public init(socket: Socket) {
        self.socket = socket
    }

    /// The dedicated server-side channel this workflow subscribes to.
    /// Subclasses MUST override.
    open var channelName: String {
        fatalError("BaseWorkflow subclasses must override `channelName`")
    }

    /// Kicks off the (lazy) subscription to `channelName` if it has not
    /// started yet, and returns `self` for chaining.
    ///
    /// Idempotent — only the first call schedules a network round-trip;
    /// subsequent calls reuse the in-flight task.
    @discardableResult
    public func connect() -> Self {
        if subscribeTask == nil {
            let channel = channelName
            let sock = socket
            subscribeTask = Task { [weak self] in
                let raw = try await sock.subscribe(channel: channel)
                guard let typed = raw as? Subscription else {
                    throw ARTError.serverError(
                        "Channel \(channel) did not yield a Subscription"
                    )
                }
                self?.subscription = typed
                return typed
            }
        }
        return self
    }

    /// Returns the active `Subscription`, kicking off `connect()` if it has
    /// not yet been invoked.
    ///
    /// Intended for use by collaborators (`AgentThread`,
    /// `Orchestrator.thread`); rarely called directly from app code.
    public func getSubscription() async throws -> Subscription {
        if let subscription { return subscription }
        if subscribeTask == nil { _ = connect() }
        return try await subscribeTask!.value
    }
}
