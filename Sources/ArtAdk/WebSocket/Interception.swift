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
        response["content"]          = (try? ArtJSON.stringify(content)) ?? ""
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

        var config: [String: Any] = [
            "channel": channel, "namespace": namespace_,
            "event": event, "interceptor_name": interceptorName,
            "from": from, "to": to as Any
        ]

        // Forward agentic routing metadata so the server can correlate
        // intercepted frames on agent/orchestrator channels. Flows through
        // createResponse (which copies `config`) into the resolve/reject
        // response.
        for k in ["to_username", "thread_id", "node_id", "agent_node_id",
                  "agent_id", "environment_id", "configuration_id", "root_workflow_id"] {
            if let v = request[k] { config[k] = v }
        }

        // Accept a JSON object or array. An object that
        // echoes the envelope (`attempt_id` / `pipeline_id`) is unwrapped to
        // its `data`; an array is sent as-is.
        let resolve: (Any) -> Void = { [weak self] data in
            guard let self else { return }
            let content: Any
            if let dict = data as? [String: Any] {
                if dict["attempt_id"] != nil || dict["pipeline_id"] != nil {
                    content = dict["data"] ?? [String: Any]()
                } else {
                    content = dict
                }
            } else if let array = data as? [Any] {
                content = array
            } else {
                ArtLog.error("Invalid data: Expected a JSON object or array of objects.")
                return
            }
            let response = self.createResponse(
                config: config, id: id, refId: refId,
                channel: channel, namespace: namespace_,
                event: event, pipelineId: pipelineId,
                interceptorName: interceptorName, attemptId: attemptId,
                type: "resolve", content: content
            )
            self.sendJSON(response)
        }

        let reject: (String) -> Void = { [weak self] error in
            guard let self else { return }
            let raw = request["data"] ?? NSNull()
            let errResponse: [String: Any] = ["rawData": raw, "error": error]
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
        // Echo agentic routing metadata on the IA acknowledge so the server
        // can correlate the intercepted frame.
        ["channel", "namespace", "id", "ref_id", "from", "to", "to_username",
         "pipeline_id", "interceptor_name", "attempt_id",
         "thread_id", "node_id", "agent_node_id", "agent_id",
         "environment_id", "configuration_id", "root_workflow_id"].forEach { k in
            if let v = request[k] { response[k] = v }
        }
        if let data = request["data"] {
            response["content"] = (try? ArtJSON.stringify(data)) ?? ""
        }
        sendJSON(response)
    }

    // MARK: - handleMessage (called by Socket)
    public func handleMessage(channel: String, data: [String: Any]) async {
        var mutable = data
        if let dataStr = data["data"] as? String, let parsed = ArtJSON.parse(dataStr) {
            mutable["data"] = parsed
        }
        execute(request: mutable)
    }

    private func sendJSON(_ dict: [String: Any]) {
        do {
            _ = websocketHandler.sendMessage(try ArtJSON.stringify(dict))
        } catch {
            ArtLog.error("Interceptor response is not JSON-serializable: \(error)")
        }
    }
}
