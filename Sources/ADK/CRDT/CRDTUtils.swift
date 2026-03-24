// Sources/ARTSdk/CRDT/CRDTUtils.swift

import Foundation

// MARK: - generateId
public func generateId() -> String {
    let ts = Int64(Date().timeIntervalSince1970 * 1000)
    let rand = String(Int.random(in: 0..<Int(pow(36.0, 6.0))), radix: 36)
    return "\(ts)-\(rand)"
}

// MARK: - nowMs
public func nowMs() -> Double {
    return Double(Date().timeIntervalSince1970 * 1000)
}

// MARK: - defaultMeta
public func defaultMeta(replicaId: String = "client") -> LDMeta {
    return LDMeta(updatedAt: Int( nowMs()), version: 1, replicaId: replicaId)
}

// MARK: - determineType
public func determineType(_ value: LDValue) -> LDEntry.LDEntryType {
    switch value {
    case .string: return .string
    case .number: return .number
    case .boolean: return .boolean
    case .array: return .array
    case .map: return .object
    case .null: return .object
    }
}

// MARK: - toLDValue  (converts Any → LDValue)
public func toLDValue(_ v: Any?, replicaId: String = "client") -> LDValue {
    guard let v = v else { return .null }

    if let s = v as? String { return .string(s) }
    if let b = v as? Bool   { return .boolean(b) }
    if let n = v as? Double { return .number(n) }
    if let n = v as? Int    { return .number(Double(n)) }
    if let n = v as? Float  { return .number(Double(n)) }

    if let arr = v as? [Any] {
        let ldArr = LDArray(meta: defaultMeta(replicaId: replicaId))
        var prev: String? = nil
        for item in arr {
            let id = generateId()
            let ldVal = toLDValue(item, replicaId: replicaId)
            let entry = LDEntry(
                id: id, key: id,
                type: determineType(ldVal),
                value: ldVal,
                meta: {
                    var m = defaultMeta(replicaId: replicaId)
                    m.after = .some(prev)
                    return m
                }()
            )
            ldArr.entries[id] = entry
            prev = id
        }
        ldArr.head = firstAfter(ldArr, after: nil)
        return .array(ldArr)
    }

    if let dict = v as? [String: Any] {
        let ldMap = LDMap(meta: defaultMeta(replicaId: replicaId))
        for (k, val) in dict {
            // CRITICAL FIX: Only create simple values, not nested entries
            // The nesting will be handled by the set() method
            let ldVal: LDValue
            
            // Check if the value is already a primitive
            if val is String || val is Double || val is Int || val is Bool {
                ldVal = toLDValue(val, replicaId: replicaId)
            } else if let nestedDict = val as? [String: Any] {
                // Recursively handle nested dictionaries
                ldVal = toLDValue(nestedDict, replicaId: replicaId)
            } else {
                ldVal = .null
            }
            
            ldMap.index[k] = LDEntry(
                id: generateId(), key: k,
                type: determineType(ldVal),
                value: ldVal,
                meta: defaultMeta(replicaId: replicaId)
            )
        }
        return .map(ldMap)
    }

    return .null
}

// MARK: - fromAnyToLDMap  (used for snapshot init)
public func fromAnyToLDMap(_ v: Any?) -> LDMap {
    guard let v = v else { return LDMap() }
    if let m = v as? LDMap { return m }
    if case .map(let m) = toLDValue(v) { return m }
    return LDMap()
}

// MARK: - toAny (LDValue → plain Swift Any for serialisation)
public func toAny(_ val: LDValue) -> Any {
    switch val {
    case .string(let s): return s
    case .number(let n): return n
    case .boolean(let b): return b
    case .null: return NSNull()
    case .map(let m):
        var out: [String: Any] = [:]
        for (k, e) in m.index { out[k] = toAny(e.value) }
        return out
    case .array(let a):
        let ids = linearizeRGA(a)
        return ids.compactMap { a.entries[$0] }.map { toAny($0.value) }
    }
}

// MARK: - isLDEntry helper
public func isLDEntry(_ x: Any) -> Bool {
    return x is LDEntry
}

// MARK: - toContainer helper
public enum LDContainer {
    case map(LDMap)
    case array(LDArray)
}

public func toContainer(_ val: LDValue) throws -> LDContainer {
    switch val {
    case .map(let m): return .map(m)
    case .array(let a): return .array(a)
    default: throw ARTError.invalidPath("Value is not a container")
    }
}


// MARK: - RGA linearize
public func linearizeRGA(_ arr: LDArray) -> [String] {
    var afterToKids: [String?: [LDEntry]] = [:]

    for (_, e) in arr.entries {
        // after is Optional<Optional<String>>; inner nil = head
        let after: String?
        if let outerAfter = e.meta.after {
            after = outerAfter  // could be nil (head) or a string (predecessor)
        } else {
            after = nil  // treat as head when field not set
        }
        afterToKids[after, default: []].append(e)
    }

    // Sort siblings by (updatedAt, replicaId, id) descending for RGA
    for key in afterToKids.keys {
        afterToKids[key]?.sort { a, b in
            if a.meta.updatedAt != b.meta.updatedAt {
                return a.meta.updatedAt < b.meta.updatedAt
            }
            if a.meta.replicaId != b.meta.replicaId {
                return a.meta.replicaId < b.meta.replicaId
            }
            return a.id < b.id
        }
    }

    var out: [String] = []
    var seen = Set<String>()

    func walk(_ parent: String?) {
        let kids = afterToKids[parent] ?? []
        for e in kids {
            guard !seen.contains(e.id) else { continue }
            seen.insert(e.id)
            if e.meta.tombstone != true { out.append(e.id) }
            walk(e.id)
        }
    }

    walk(nil)
    return out
}

// MARK: - Helper used during toLDValue array build
private func firstAfter(_ arr: LDArray, after: String?) -> String? {
    let ids = arr.entries.keys.filter { id in
        guard let e = arr.entries[id] else { return false }
        if let outerAfter = e.meta.after {
            return outerAfter == after
        }
        return after == nil
    }.sorted()
    return ids.first
}

// MARK: - ARTError
public enum ARTError: Error, LocalizedError {
    case forbidden(String)
    case authenticationFailed(String)
    case invalidPath(String)
    case notConnected
    case encryptionError(String)
    case decryptionError(String)
    case timeout(String)
    case serverError(String)
    case channelNotFound(String)
    case ackTimeout

    public var errorDescription: String? {
        switch self {
        case .forbidden(let m):          return "Forbidden: \(m)"
        case .authenticationFailed(let m): return "Auth failed: \(m)"
        case .invalidPath(let m):        return "Invalid path: \(m)"
        case .notConnected:              return "Not connected"
        case .encryptionError(let m):    return "Encryption error: \(m)"
        case .decryptionError(let m):    return "Decryption error: \(m)"
        case .timeout(let m):            return "Timeout: \(m)"
        case .serverError(let m):        return "Server error: \(m)"
        case .channelNotFound(let m):    return "Channel not found: \(m)"
        case .ackTimeout:                return "ACK timeout"
        }
    }
}



