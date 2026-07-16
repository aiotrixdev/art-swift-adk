// Sources/ARTSdk/CRDT/CRDTTypes.swift


import Foundation

// MARK: - LDValue
public indirect enum LDValue {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case map(LDMap)
    case array(LDArray)
    case null
}

// MARK: - LDMeta
public struct LDMeta {
    public var updatedAt: Int
    public var version: Int
    public var replicaId: String
    public var order: Int?
    public var tombstone: Bool?
    // RGA fields
    public var after: String??
    public var next: String?
    
    public init(
        updatedAt: Int = Int(Date().timeIntervalSince1970 * 1000),
        version: Int = 1,
        replicaId: String = "client",
        order: Int? = nil,
        tombstone: Bool? = nil,
        after: String?? = nil,
        next: String? = nil
    ) {
        self.updatedAt = updatedAt
        self.version = version
        self.replicaId = replicaId
        self.order = order
        self.tombstone = tombstone
        self.after = after
        self.next = next
    }
}

// MARK: - LDEntry
public class LDEntry {
    public var id: String
    public var key: String
    public var type: LDEntryType
    public var value: LDValue
    public var meta: LDMeta
    
    public enum LDEntryType: String, Codable {
        case string, number, boolean, object, array
    }
    
    public init(id: String, key: String, type: LDEntryType, value: LDValue, meta: LDMeta) {
        self.id = id
        self.key = key
        self.type = type
        self.value = value
        self.meta = meta
    }
}

// MARK: - LDMap
public class LDMap {
    public var index: [String: LDEntry]
    public var meta: LDMeta
    
    public init(index: [String: LDEntry] = [:], meta: LDMeta = LDMeta()) {
        self.index = index
        self.meta = meta
    }
}

// MARK: - LDArray (RGA)
public class LDArray {
    public var entries: [String: LDEntry]
    public var head: String?
    public var meta: LDMeta
    
    public init(entries: [String: LDEntry] = [:], head: String? = nil, meta: LDMeta = LDMeta()) {
        self.entries = entries
        self.head = head
        self.meta = meta
    }
}

// MARK: - CRDTOperation
public enum CRDTOperation {
    case add(path: [String], entry: LDEntry?, timestamp: Int, replicaId: String)
    case replace(path: [String], entry: LDEntry, timestamp: Int, replicaId: String)
    case remove(path: [String], timestamp: Int, replicaId: String)
    case arrayPush(path: [String], ref: String?, entry: LDEntry, timestamp: Int, replicaId: String)
    case arrayUnshift(path: [String], entry: LDEntry, timestamp: Int, replicaId: String)
    case arrayRemove(path: [String], ref: String, timestamp: Int, replicaId: String)
    
    public var path: [String] {
        switch self {
        case .add(let p, _, _, _): return p
        case .replace(let p, _, _, _): return p
        case .remove(let p, _, _): return p
        case .arrayPush(let p, _, _, _, _): return p
        case .arrayUnshift(let p, _, _, _): return p
        case .arrayRemove(let p, _, _, _): return p
        }
    }
    
    public var timestamp: Int {
        switch self {
        case .add(_, _, let t, _): return t
        case .replace(_, _, let t, _): return t
        case .remove(_, let t, _): return t
        case .arrayPush(_, _, _, let t, _): return t
        case .arrayUnshift(_, _, let t, _): return t
        case .arrayRemove(_, _, let t, _): return t
        }
    }
    
    public var replicaId: String {
        switch self {
        case .add(_, _, _, let r): return r
        case .replace(_, _, _, let r): return r
        case .remove(_, _, let r): return r
        case .arrayPush(_, _, _, _, let r): return r
        case .arrayUnshift(_, _, _, let r): return r
        case .arrayRemove(_, _, _, let r): return r
        }
    }
}

