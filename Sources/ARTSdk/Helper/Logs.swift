//
//  Logs.swift
//  ADK
//
//  Created by SSA on 16/03/26.
//

//
//  APITracer.swift
//  ADK_iOS
//
//  Created by SSA on 04/02/26.
//

// Tracer.swift
import Foundation

public enum TraceLevel: String {
    case info = "INFO"
    case debug = "DEBUG"
    case warn = "WARN"
    case error = "ERROR"
}

public struct Tracer {
    public static func log(
        _ level: TraceLevel,
        _ message: String,
        meta: [String: Any] = [:]
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let metaString = meta.isEmpty ? "" : " | \(meta)"
        print("[\(timestamp)] [\(level.rawValue)] \(message)\(metaString)\n")
    }
}


final class TracedURLSessionDelegate: NSObject,
                                     URLSessionTaskDelegate,
                                     URLSessionDataDelegate {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard
            let transaction = metrics.transactionMetrics.last,
            let request = task.originalRequest,
            let response = task.response as? HTTPURLResponse
        else { return }

        let durationMs: Double? = {
            guard
                let start = transaction.fetchStartDate,
                let end = transaction.responseEndDate
            else { return nil }

            return end.timeIntervalSince(start) * 1000
        }()

        Tracer.log(
            .info,
            "HTTP Request Completed",
            meta: [
                "url": request.url?.absoluteString ?? "",
                "method": request.httpMethod ?? "",
                "status": response.statusCode,
                "duration_ms": durationMs ?? -1
            ]
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            Tracer.log(.error, "HTTP Request Failed", meta: [
                "error": error.localizedDescription
            ])
        }
    }
}

import Foundation

enum LogTracer {
    
    #if DEBUG
    private static let isEnabled = true
    #else
    private static let isEnabled = false
    #endif
    
    static func log(_ message: String) {
        guard isEnabled else { return }
        print(message)
    }
    
    static func printJSONData(_ data: Data, title: String? = nil) {
        guard isEnabled else { return }
        
        if let title = title {
            print("\(title)")
        }
        
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            let prettyData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted]
            )
            
            if let prettyString = String(data: prettyData, encoding: .utf8) {
                print(prettyString)
            }
        } catch {
            print("❌ Failed to pretty print JSON:", error)
        }
        print("\n")
    }
    
    static func printJSONString(_ jsonString: String, title: String? = nil) {
           guard isEnabled else { return }
           
           if let title = title {
               print("\n✅ \(title):")
           }
           
           guard let data = jsonString.data(using: .utf8) else {
               print("❌ Invalid JSON String")
               return
           }
           
           prettyPrintData(data)
        print("\n")
       }
    
    static func prettyPrintData(_ data: Data, title: String? = nil) {
            guard isEnabled else { return }
            
            if let title = title {
                print("🔹 \(title)")
            }
            
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                let prettyData = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted]
                )
                
                if let prettyString = String(data: prettyData, encoding: .utf8) {
                    print(prettyString)
                }
            } catch {
                print("❌ Failed to pretty print Data:", error)
            }
        print("\n")
        }
    static func printDATA<T: Encodable>(_ value: T, title: String? = nil) {
        guard isEnabled else { return }
        
        if let title = title {
            print("✅ \(title):")
        }
        
        do {
            let data = try JSONEncoder().encode(value)
            printJSONData(data)
        } catch {
            print("❌ Encoding failed:", error)
        }
        print("\n")
    }
    
}
