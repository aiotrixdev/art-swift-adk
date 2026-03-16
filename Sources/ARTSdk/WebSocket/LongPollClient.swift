// Sources/ARTSdk/WebSocket/LongPollClient.swift

import Foundation

public final class LongPollClient {

    private let opts: LongPollOptions
    private var connectionId: String?
    private var isRunning = false
    private var pollTask: Task<Void, Never>?

    public init(opts: LongPollOptions) {
        self.opts = opts
        self.connectionId = opts.initialConnectionId
    }

    // MARK: - Control
    public func start(connectionId: String? = nil) {
        if isRunning { return }
        if let cid = connectionId { self.connectionId = cid }
        isRunning = true
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    public func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
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
                if let cid = connectionId {
                    var items = components.queryItems ?? []
                    items.append(URLQueryItem(name: "connection_id", value: cid))
                    components.queryItems = items
                }
                guard let url = components.url else { continue }

                var req = URLRequest(url: url)
                req.timeoutInterval = 35  // longer than server hold time

                let headers = try await opts.getAuthHeaders()
                headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse else { continue }

                // 204 = no messages
                if http.statusCode == 204 {
                    try await Task.sleep(nanoseconds: UInt64(backoffEmpty * 1_000_000))
                    backoffEmpty = min(backoffEmpty * 2, maxBackoff)
                    continue
                }

                guard http.statusCode == 200 else {
                    opts.onError?(ARTError.serverError("LongPoll HTTP \(http.statusCode)"))
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000))
                    continue
                }

                backoffEmpty = Double(opts.emptyPollDelayMs)

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if connectionId == nil {
                        connectionId = json["connection_id"] as? String
                    }
                    if let messages = json["messages"] as? [Any], !messages.isEmpty {
                        opts.onMessages(messages)
                    }
                }

            } catch {
                if Task.isCancelled { return }
                opts.onError?(error)
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000))
            }
        }
    }
}
