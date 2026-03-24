// Sources/ARTSdk/WebSocket/Interception.swift

import Foundation

public final class Interception {

    private let interceptorName: String
    private var interceptorData: Any?
    private let websocketHandler: IWebsocketHandler
    private let fn: ([String: Any], @escaping (Any) -> Void, @escaping (String) -> Void) -> Void
    public let emitter: EventEmitter = EventEmitter()

    public init(
        interceptor: String,
        fn: @escaping ([String: Any], @escaping (Any) -> Void, @escaping (String) -> Void) -> Void,
        websocketHandler: IWebsocketHandler
    ) {
        self.interceptorName  = interceptor
        self.fn               = fn
        self.websocketHandler = websocketHandler
    }

    // MARK: - ValidateInterception
    public func validateInterception() async throws {
        interceptorData = try await get_interceptor_config(
            interceptor: interceptorName,
            websocketHandler: websocketHandler
        )
    }

    public func reconnect() {
        print("[ART] reconnecting interceptor \(interceptorName)")
        Task { try? await validateInterception() }
    }
    
    private func createResponse(
        config: [String: Any],
        id: String, refId: String,
        channel: String, namespace: String,
        event: String, pipelineId: String,
        interceptorName: String, attemptId: String,
        type: String, content: Any
    ) -> [String: Any] {
        var response = config
        response["channel"]          = channel
        response["namespace"]        = namespace
        response["event"]            = event
        response["id"]               = id
        response["ref_id"]           = refId
        response["return_flag"]      = type
        response["pipeline_id"]      = pipelineId
        response["interceptor_name"] = interceptorName
        response["attempt_id"]       = attemptId
        response["content"]          = (try? JSONSerialization.data(withJSONObject: content))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return response
    }

    // MARK: - Execute
    private func execute(request: [String: Any]) {
        acknowledge(request)

        let id              = request["id"]              as? String ?? ""
        let channel         = request["channel"]         as? String ?? ""
        let namespace_      = request["namespace"]       as? String ?? ""
        let from            = request["from"]            as? String ?? ""
        let to              = request["to"]
        let event           = request["event"]           as? String ?? ""
        let interceptorName = request["interceptor_name"] as? String ?? ""
        let pipelineId      = request["pipeline_id"]    as? String ?? ""
        let attemptId       = request["attempt_id"]     as? String ?? ""
        let refId           = request["ref_id"]         as? String ?? ""

        let config: [String: Any] = [
            "channel": channel, "namespace": namespace_,
            "event": event, "interceptor_name": interceptorName,
            "from": from, "to": to as Any
        ]

        let resolve: (Any) -> Void = { [weak self] data in
            guard let self else { return }
            guard let dataDict = data as? [String: Any] ?? (data as? [[String: Any]]).map({ ["items": $0] }) else {
                print("[ART] Interception resolve: invalid data (must be JSON object)")
                return
            }
            var sanitized = dataDict
            if sanitized["attempt_id"] != nil || sanitized["pipeline_id"] != nil {
                sanitized = sanitized["data"] as? [String: Any] ?? [:]
            }
            let response = self.createResponse(
                config: config, id: id, refId: refId,
                channel: channel, namespace: namespace_,
                event: event, pipelineId: pipelineId,
                interceptorName: interceptorName, attemptId: attemptId,
                type: "resolve", content: sanitized
            )
            self.sendJSON(response)
        }

        let reject: (String) -> Void = { [weak self] error in
            guard let self else { return }
            let raw = request["data"]
            let errResponse: [String: Any] = ["rawData": raw as Any, "error": error]
            let response = self.createResponse(
                config: config, id: id, refId: refId,
                channel: channel, namespace: namespace_,
                event: event, pipelineId: pipelineId,
                interceptorName: interceptorName, attemptId: attemptId,
                type: "reject", content: errResponse
            )
            self.sendJSON(response)
        }

        fn(request, resolve, reject)
    }

    // MARK: - Acknowledge
    private func acknowledge(_ request: [String: Any]) {
        var response: [String: Any] = ["return_flag": "IA"]
        ["channel", "namespace", "id", "ref_id", "from", "to",
         "pipeline_id", "interceptor_name", "attempt_id"].forEach { k in
            if let v = request[k] { response[k] = v }
        }
        if let data = request["data"] {
            response["content"] = (try? JSONSerialization.data(withJSONObject: data))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        sendJSON(response)
    }

    // MARK: - handleMessage (called by Socket)
    public func handleMessage(channel: String, data: [String: Any]) async {
        var mutable = data
        if let dataStr = data["data"] as? String,
           let parsed = dataStr.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) {
            mutable["data"] = parsed
        }
        execute(request: mutable)
    }

    private func sendJSON(_ dict: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let str  = String(data: data, encoding: .utf8) {
            _ = websocketHandler.sendMessage(str)
        }
    }
}
