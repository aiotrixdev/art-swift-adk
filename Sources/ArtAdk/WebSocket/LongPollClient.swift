// Sources/ARTSdk/WebSocket/LongPollClient.swift

import Foundation

/// HTTP long-poll transport used when the WebSocket connection is
/// unavailable.
///
/// A failed poll is reported to `onError` as an `AuthHttpError`. The loop
/// stops when the server rejects the credentials (HTTP 401 or 403), whether
/// while `getAuthHeaders` gets a token or on the poll itself.
public final class LongPollClient {

    private let opts: LongPollOptions
    private let lock = ArtLock()
    private var connectionId: String?
    private var running = false
    private var pollTask: Task<Void, Never>?

    public init(opts: LongPollOptions) {
        self.opts = opts
        self.connectionId = opts.initialConnectionId
    }

    private var isRunning: Bool { lock.sync { running } }

    // MARK: - Control
    public func start(connectionId: String? = nil) {
        lock.sync {
            if running { return }
            if let cid = connectionId, !cid.isEmpty { self.connectionId = cid }
            running = true
            pollTask = Task { [weak self] in await self?.pollLoop() }
        }
    }

    public func stop() {
        let task: Task<Void, Never>? = lock.sync {
            running = false
            let task = pollTask
            pollTask = nil
            return task
        }
        task?.cancel()
    }

    // MARK: - Poll loop
    private func pollLoop() async {
        var backoffEmpty = Double(opts.emptyPollDelayMs)
        let maxBackoff   = Double(opts.maxEmptyPollDelayMs)
        let retryDelay   = Double(opts.retryDelayMs)

        while isRunning && !Task.isCancelled {
            do {
                // Build URL
                guard var components = URLComponents(string: opts.endpoint) else {
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000))
                    continue
                }
                if let cid = lock.sync({ connectionId }) {
                    var items = components.queryItems ?? []
                    items.append(URLQueryItem(name: "connection_id", value: cid))
                    components.queryItems = items
                }
                guard let url = components.url else { continue }

                var req = URLRequest(url: url)
                req.timeoutInterval = 35  // longer than server hold time

                let headers = try await opts.getAuthHeaders()
                if !isRunning { return }
                headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse else { continue }

                // 204 = no messages
                if http.statusCode == 204 {
                    opts.onResponse?()
                    try await Task.sleep(nanoseconds: UInt64(backoffEmpty * 1_000_000))
                    backoffEmpty = min(backoffEmpty * 2, maxBackoff)
                    continue
                }

                guard http.statusCode == 200 else {
                    let body = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                    let message = (body as? [String: Any])?["message"] as? String
                    throw AuthHttpError(
                        (message?.isEmpty == false ? message : nil)
                            ?? "Connection request failed (HTTP \(http.statusCode)).",
                        status: http.statusCode,
                        body: body
                    )
                }

                backoffEmpty = Double(opts.emptyPollDelayMs)
                opts.onResponse?()

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    lock.sync {
                        if connectionId == nil {
                            connectionId = json["connection_id"] as? String
                        }
                    }
                    if let messages = json["messages"] as? [Any], !messages.isEmpty {
                        opts.onMessages(messages)
                    }
                }

            } catch {
                if Task.isCancelled || !isRunning { return }
                opts.onError?(error)
                // Rejected credentials cannot succeed on retry.
                if isTerminalAuthError(error) {
                    lock.sync { running = false }
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000))
            }
        }
    }
}
