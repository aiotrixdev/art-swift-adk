// Sources/ARTSdk/CRDT/CRDT.swift


import Foundation

// MARK: - CRDTListener
public typealias CRDTListener = (Any) -> Void

// MARK: - CRDTProxy  (@dynamicMemberLookup  ≈ JS Proxy)
@dynamicMemberLookup
public final class CRDTProxy {
    internal let crdt: CRDT
    internal let parentPath: [String]
    
    internal init(crdt: CRDT, parentPath: [String]) {
        self.crdt = crdt
        self.parentPath = parentPath
    }
    
    // MARK: Object property access
    public subscript(dynamicMember key: String) -> CRDTProxy {
        return CRDTProxy(crdt: crdt, parentPath: parentPath + [key])
    }
    
    // MARK: Array / object keyed subscript
    public subscript(key: String) -> CRDTProxy {
        return CRDTProxy(crdt: crdt, parentPath: parentPath + [key])
    }
    
    // MARK: Numeric index subscript
    public subscript(index: Int) -> CRDTProxy {
        guard let id = crdt.getArrayIdAt(path: parentPath, idx: index) else {
            return CRDTProxy(crdt: crdt, parentPath: parentPath + ["__oob_\(index)"])
        }
        return CRDTProxy(crdt: crdt, parentPath: parentPath + [id])
    }
    
    // MARK: Read scalar value
    public var value: Any? {
        return crdt.readJSONAt(path: parentPath)
    }
    
    // MARK: Write scalar / object
    public func set(_ value: Any?) {
        
        let key = parentPath.last ?? ""
        let full = parentPath
        
        let parents = crdt.ensureParentsOps(full: full)
        
        let ldVal = toLDValue(value)
        
        func patchReplica(_ v: LDValue) {
            switch v {
            case .map(let m):
                for (_, e) in m.index {
                    e.meta.replicaId = crdt.clientReplicaId
                    patchReplica(e.value)
                }
            case .array(let a):
                for (_, e) in a.entries {
                    e.meta.replicaId = crdt.clientReplicaId
                    patchReplica(e.value)
                }
            default:
                break
            }
        }
        
        patchReplica(ldVal)
        
        let entry = LDEntry(
            id: generateId(),
            key: key,
            type: determineType(ldVal),
            value: ldVal,
            meta: LDMeta(
                updatedAt:Int( nowMs()),
                version: 1,
                replicaId: crdt.clientReplicaId
            )
        )
        
        crdt.appendPending(parents)
        
        crdt.appendPending(
            .replace(
                path: full,
                entry: entry,
                timestamp: Int(nowMs()),
                replicaId: crdt.clientReplicaId
            )
        )
        
        crdt.scheduleFlush()
    }
    
    public func delete() {
        if crdt.readJSONAt(path: parentPath) == nil { return }
        crdt.appendPending(.remove(path: parentPath, timestamp: Int(nowMs()), replicaId: crdt.clientReplicaId))
        crdt.scheduleFlush()
    }
    
    // MARK: Array push
    @discardableResult
    public func push(_ items: Any...) -> Int {
        crdt.ensureArrayContainer(path: parentPath)
        var cur = crdt.visibleIdsFor(path: parentPath)
        var prev: String? = cur.last
        
        for item in items {
            let id = generateId()
            let ldVal = toLDValue(item)
            var m = LDMeta(updatedAt: Int( nowMs()), version: 1, replicaId: crdt.clientReplicaId)
            m.after = .some(prev)
            let entry = LDEntry(id: id, key: id, type: determineType(ldVal), value: ldVal, meta: m)
            crdt.appendPending(.arrayPush(path: parentPath, ref: prev, entry: entry, timestamp: Int(m.updatedAt), replicaId: crdt.clientReplicaId))
            cur.append(id)
            prev = id
        }
        crdt.scheduleFlush()
        return cur.count
    }
    
    // MARK: Array unshift
    @discardableResult
    public func unshift(_ items: Any...) -> Int {
        crdt.ensureArrayContainer(path: parentPath)
        for item in items {
            let id = generateId()
            let ldVal = toLDValue(item)
            var m = LDMeta(updatedAt: Int( nowMs()), version: 1, replicaId: crdt.clientReplicaId)
            m.after = .some(nil)  // insert at head
            let entry = LDEntry(id: id, key: id, type: determineType(ldVal), value: ldVal, meta: m)
            crdt.appendPending(.arrayUnshift(path: parentPath, entry: entry, timestamp: Int(m.updatedAt), replicaId: crdt.clientReplicaId))
        }
        crdt.scheduleFlush()
        return crdt.visibleIdsFor(path: parentPath).count
    }
    
    // MARK: Array pop
    @discardableResult
    public func pop() -> Any? {
        let ids = crdt.visibleIdsFor(path: parentPath)
        guard let lastId = ids.last else { return nil }
        let arr = crdt.getContainerAt(path: parentPath)
        var ret: Any? = nil
        if case .array(let a) = arr, let e = a.entries[lastId] {
            ret = toAny(e.value)
        }
        crdt.appendPending(.arrayRemove(path: parentPath, ref: lastId, timestamp: Int(nowMs()), replicaId: crdt.clientReplicaId))
        crdt.scheduleFlush()
        return ret
    }
    
    // MARK: Array removeAt
    @discardableResult
    public func removeAt(_ index: Int) -> Any? {
        guard let id = crdt.getArrayIdAt(path: parentPath, idx: index) else { return nil }
        let arr = crdt.getContainerAt(path: parentPath)
        var ret: Any? = nil
        if case .array(let a) = arr, let e = a.entries[id] {
            ret = toAny(e.value)
        }
        crdt.appendPending(.arrayRemove(path: parentPath, ref: id, timestamp: Int(nowMs()), replicaId: crdt.clientReplicaId))
        crdt.scheduleFlush()
        return ret
    }
    
    // MARK: Array splice
    @discardableResult
    public func splice(start: Int, deleteCount: Int? = nil, insert items: [Any] = []) -> [String] {
        let ids = crdt.visibleIdsFor(path: parentPath)
        let len = ids.count
        let s = min(max(0, start), len)
        let dc = deleteCount == nil ? (len - s) : max(0, min(deleteCount!, len - s))
        
        for i in 0..<dc {
            let id = ids[s + i]
            crdt.appendPending(.arrayRemove(path: parentPath, ref: id, timestamp: Int(nowMs()), replicaId: crdt.clientReplicaId))
        }
        
        var prev: String? = s > 0 ? ids[s - 1] : nil
        for item in items {
            let id = generateId()
            let ldVal = toLDValue(item)
            var m = LDMeta(updatedAt: Int( nowMs()), version: 1, replicaId: crdt.clientReplicaId)
            m.after = .some(prev)
            let entry = LDEntry(id: id, key: id, type: determineType(ldVal), value: ldVal, meta: m)
            if prev != nil {
                crdt.appendPending(.arrayPush(path: parentPath, ref: prev, entry: entry, timestamp: Int(m.updatedAt), replicaId: crdt.clientReplicaId))
            } else {
                crdt.appendPending(.arrayUnshift(path: parentPath, entry: entry, timestamp: Int(m.updatedAt), replicaId: crdt.clientReplicaId))
            }
            prev = id
        }
        
        crdt.scheduleFlush()
        return ids[s..<(s + dc)].map { $0 }
    }
    
    // MARK: Array length
    public var length: Int {
        return crdt.visibleIdsFor(path: parentPath).count
    }
    
    // MARK: Flush
    public func flush() async {
        await crdt.flush()
    }
}

// MARK: - CRDT Engine
public final class CRDT {
    internal var snapshot: LDMap
    private var listeners: [String: [CRDTListener]] = [:]
    private var mergeCallback: ([CRDTOperation]) -> Void
    private var rootProxy: CRDTProxy?
    internal var pending: [CRDTOperation] = []
    internal var clientReplicaId: String = "client"
    
    private var lastFlushAt: Double = 0
    private let minFlushMs: Double = 50
    private var trailingTimer: Task<Void, Never>?
    private let queue = DispatchQueue(label: "crdt.queue", qos: .userInitiated)
    
    // MARK: Init
    public init(initial: LDMap, mergeCallback: @escaping ([CRDTOperation]) -> Void) {
        self.snapshot = initial
        self.mergeCallback = mergeCallback
    }
    
    // MARK: Public accessors
    public func state() -> CRDTProxy {
        if rootProxy == nil { rootProxy = CRDTProxy(crdt: self, parentPath: []) }
        return rootProxy!
    }
    
    public func setMergeCallback(_ cb: @escaping ([CRDTOperation]) -> Void) {
        self.mergeCallback = cb
    }
    
    internal func appendPending(_ ops: [CRDTOperation]) {
        queue.sync {
            pending.append(contentsOf: ops)
        }
    }

    internal func appendPending(_ op: CRDTOperation) {
        queue.sync {
            pending.append(op)
        }
    }
    
    public func setReplicaId(_ id: String) { clientReplicaId = id }
    public func getReplicaId() -> String    { clientReplicaId }
    public func getState() -> LDMap        { snapshot }
    
    // MARK: Flush
    public func flush() async {

        var ops: [CRDTOperation] = []

        queue.sync {
            if pending.isEmpty { return }
            ops = compactOps(pending)
            pending.removeAll()
        }

        if ops.isEmpty { return }

        merge(ops)
        mergeCallback(ops)
    }
    
    internal func scheduleFlush() {

        queue.sync {

            if trailingTimer != nil { return }

            trailingTimer = Task { [weak self] in
                guard let self else { return }

                try? await Task.sleep(nanoseconds: UInt64(minFlushMs * 1_000_000))

                self.queue.sync {
                    self.trailingTimer = nil
                }

                await self.flush()
            }
        }
    }
    
    // MARK: - Op compaction
    private func compactOps(_ batch: [CRDTOperation]) -> [CRDTOperation] {
        var parentAddsSeen = Set<String>()
        var parentAdds: [CRDTOperation] = []
        var arrayOps: [CRDTOperation] = []
        
        struct LeafAcc {
            enum Kind { case replace(LDEntry), remove }
            var kind: Kind
        }
        var leafMap: [String: LeafAcc] = [:]
        
        for op in batch {
            switch op {
            case .arrayPush, .arrayUnshift, .arrayRemove:
                arrayOps.append(op)
            case .add(let path, let entry, _, _):
                if let e = entry {
                    switch e.type {
                    case .object, .array:
                        let k = path.joined(separator: ".")
                        if !parentAddsSeen.contains(k) {
                            parentAddsSeen.insert(k)
                            parentAdds.append(op)
                        }
                        continue
                    default: break
                    }
                }
                let key = op.path.joined(separator: ".")
                if let e = entry { leafMap[key] = LeafAcc(kind: .replace(e)) }
            case .replace(let path, let entry, _, _):
                let key = path.joined(separator: ".")
                leafMap[key] = LeafAcc(kind: .replace(entry))
            case .remove(let path, _, _):
                let key = path.joined(separator: ".")
                leafMap[key] = LeafAcc(kind: .remove)
            }
        }
        
        parentAdds.sort { $0.path.count < $1.path.count }
        var leaves: [CRDTOperation] = []
        for (k, acc) in leafMap {
            let path = k.split(separator: ".").map(String.init)
            switch acc.kind {
            case .remove:
                leaves.append(.remove(path: path, timestamp: Int(nowMs()), replicaId: clientReplicaId))
            case .replace(let entry):
                leaves.append(.replace(path: path, entry: entry, timestamp: Int(nowMs()), replicaId: clientReplicaId))
            }
        }
        
        return parentAdds + leaves + arrayOps
    }
    
    // MARK: - Navigation helpers
    
    internal func getContainerAt(path: [String]) -> LDValue? {
        var node: LDValue = .map(snapshot)
        for seg in path {
            switch node {
            case .map(let m):
                guard let e = m.index[seg] else { return nil }
                node = e.value
            case .array(let a):
                guard let e = a.entries[seg] else { return nil }
                node = e.value
            default:
                return nil
            }
        }
        switch node {
        case .map, .array: return node
        default: return nil
        }
    }
    
    internal func readJSONAt(path: [String]) -> Any? {
        var node: LDValue = .map(snapshot)
        for seg in path {
            switch node {
            case .map(let m):
                guard let e = m.index[seg] else { return nil }
                node = e.value
            case .array(let a):
                guard let e = a.entries[seg] else { return nil }
                node = e.value
            default: return nil
            }
        }
        return toAny(node)
    }
    
    // Navigate to the node at path (throws if not found)
    private func navigate(path: [String]) throws -> LDValue {
        var node: LDValue = .map(snapshot)
        for (i, seg) in path.enumerated() {
            if i == 0 && seg == "index" { continue }
            switch node {
            case .map(let m):
                guard let e = m.index[seg] else { throw ARTError.invalidPath(path.joined(separator: ".")) }
                node = e.value
            case .array(let a):
                guard let e = a.entries[seg] else { throw ARTError.invalidPath(path.joined(separator: ".")) }
                node = e.value
            default:
                throw ARTError.invalidPath("Cannot navigate into primitive at \(seg)")
            }
        }
        return node
    }
    
    // Navigate to the PARENT container; forceCreate creates missing maps
    @discardableResult
    private func navigateToParent(path: [String], forceCreate: Bool) throws -> LDContainer {
        var node: LDContainer = .map(snapshot)
        for i in 0..<path.count - 1 {
            let seg = path[i]
            if i == 0 && seg == "index" { continue }
            switch node {
            case .map(let m):
                if m.index[seg] == nil {
                    guard forceCreate else { throw ARTError.invalidPath(path.joined(separator: ".")) }
                    let nextSeg = path[i + 1]
                    let isArr = nextSeg.allSatisfy(\.isNumber)
                    let ldVal: LDValue = isArr ? .array(LDArray()) : .map(LDMap())
                    m.index[seg] = LDEntry(
                        id: generateId(), key: seg,
                        type: isArr ? .array : .object,
                        value: ldVal,
                        meta: LDMeta(updatedAt: Int( nowMs()), version: 1, replicaId: clientReplicaId)
                    )
                }
                let e = m.index[seg]!
                node = try toContainer(e.value)
            case .array(let a):
                if a.entries[seg] == nil {
                    guard forceCreate else { throw ARTError.invalidPath(path.joined(separator: ".")) }
                    a.entries[seg] = LDEntry(
                        id: seg, key: seg, type: .object, value: .map(LDMap()),
                        meta: LDMeta(updatedAt: Int( nowMs()), version: 1, replicaId: clientReplicaId, after: .some(nil))
                    )
                }
                node = try toContainer(a.entries[seg]!.value)
            }
        }
        return node
    }
    
    // Auto-create missing nested maps (used in merge)
    private func ensureMapParents(root: LDMap, path: [String], ts: Int, replicaId: String) {
        var node: LDContainer = .map(root)
        for i in 0..<path.count - 1 {
            let seg = path[i]
            switch node {
            case .map(let m):
                if m.index[seg] == nil {
                    m.index[seg] = LDEntry(
                        id: generateId(), key: seg, type: .object, value: .map(LDMap()),
                        meta: LDMeta(updatedAt: Int(ts), version: 1, replicaId: replicaId)
                    )
                }
                if let e = m.index[seg], case .map(let next) = e.value {
                    node = .map(next)
                } else if let e = m.index[seg], case .array(let next) = e.value {
                    node = .array(next)
                }
            case .array(let a):
                if a.entries[seg] == nil {
                    a.entries[seg] = LDEntry(
                        id: seg, key: seg, type: .object, value: .map(LDMap()),
                        meta: LDMeta(updatedAt: Int(ts), version: 1, replicaId: replicaId, after: .some(nil))
                    )
                }
                if let e = a.entries[seg], case .map(let next) = e.value {
                    node = .map(next)
                }
            }
        }
    }
    
    // MARK: - Array container helpers
    @discardableResult
    internal func ensureArrayContainer(path: [String]) -> LDArray {
        if let existing = getContainerAt(path: path), case .array(let a) = existing { return a }
        let newArr = LDArray(meta: defaultMeta(replicaId: clientReplicaId))
        let key = path.last ?? ""
        let entry = LDEntry(
            id: generateId(), key: key, type: .array, value: .array(newArr),
            meta: LDMeta(updatedAt: Int( nowMs()), version: 1, replicaId: clientReplicaId)
        )
        if path.count <= 1 {
            snapshot.index[key] = entry
        } else {
            let parentPath = Array(path.dropLast())
            if let parent = getContainerAt(path: parentPath), case .map(let m) = parent {
                m.index[key] = entry
            }
        }
        return newArr
    }
    
    // MARK: - RGA visibility (snapshot + pending overlay)
    private func pendingArrayOps(for parentPath: [String]) -> [CRDTOperation] {

        let key = parentPath.joined(separator: ".")

        return queue.sync {
            pending.filter { op in
                switch op {
                case .arrayPush(let p, _, _, _, _),
                     .arrayUnshift(let p, _, _, _),
                     .arrayRemove(let p, _, _, _):
                    return p.joined(separator: ".") == key
                default:
                    return false
                }
            }
        }
    }
    
    private func baseIdsFor(path: [String]) -> [String] {
        guard let cont = getContainerAt(path: path), case .array(let a) = cont else { return [] }
        return linearizeRGA(a)
    }
    
    internal func visibleIdsFor(path: [String]) -> [String] {
        var ids = baseIdsFor(path: path)
        for op in pendingArrayOps(for: path) {
            switch op {
            case .arrayPush(_, let ref, let entry, _, _):
                let pos = ref.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? ids.count
                ids.insert(entry.id, at: pos)
            case .arrayUnshift(_, let entry, _, _):
                ids.insert(entry.id, at: 0)
            case .arrayRemove(_, let ref, _, _):
                if let i = ids.firstIndex(of: ref) { ids.remove(at: i) }
            default: break
            }
        }
        return ids
    }
    
    internal func getArrayIdAt(path: [String], idx: Int) -> String? {
        let ids = visibleIdsFor(path: path)
        let n = ids.count
        let i = idx < 0 ? n + idx : idx
        guard i >= 0 && i < n else { return nil }
        return ids[i]
    }
    
    // MARK: - ensureParents (for object property assignment)
    internal func ensureParentsOps(full: [String]) -> [CRDTOperation] {
        var ops: [CRDTOperation] = []
        for i in 0..<full.count - 1 {
            let sub = Array(full.prefix(i + 1))
            if readJSONAt(path: sub) != nil { continue }
            let seg = full[i]
            let parentPath = Array(full.prefix(i))
            let parentCont = getContainerAt(path: parentPath)
            if case .array = parentCont { continue }  // skip; merge upserts
            let entry = LDEntry(
                id: generateId(), key: seg, type: .object, value: .map(LDMap()),
                meta: LDMeta(updatedAt: Int( nowMs()), version: 1, replicaId: clientReplicaId)
            )
            ops.append(.add(path: sub, entry: entry, timestamp: Int(nowMs()), replicaId: clientReplicaId))
        }
        return ops
    }
    
    // MARK: - Merge
    public func merge(_ ops: [CRDTOperation]) {
        for op in ops {
            switch op {
            case .arrayPush(let path, let ref, let entry, let ts, let replicaId):
                let arr = ensureArrayContainer(path: path)
                entry.meta.updatedAt = Int(ts)
                entry.meta.replicaId = replicaId
                entry.meta.after = .some(ref)
                arr.entries[entry.id] = entry
                
            case .arrayUnshift(let path, let entry, let ts, let replicaId):
                let arr = ensureArrayContainer(path: path)
                entry.meta.updatedAt = ts
                entry.meta.replicaId = replicaId
                entry.meta.after = .some(nil)
                arr.entries[entry.id] = entry
                
            case .arrayRemove(let path, let ref, let ts, let replicaId):
                let arr = ensureArrayContainer(path: path)
                if let target = arr.entries[ref] {
                    if target.meta.tombstone != true || target.meta.updatedAt <= ts {
                        target.meta.tombstone = true
                        target.meta.updatedAt = ts
                        target.meta.replicaId = replicaId
                    }
                }
                
            case .remove(let path, _, _):
                let key = path.last ?? ""
                if path.count == 1 {
                    snapshot.index.removeValue(forKey: key)
                } else {
                    let parentPath = Array(path.dropLast())
                    if let parent = try? navigateToParent(path: path, forceCreate: false) {
                        switch parent {
                        case .map(let m): m.index.removeValue(forKey: key)
                        case .array(let a): a.entries.removeValue(forKey: key)
                        }
                    }
                }
                
            case .add(let path, let entryOpt, let ts, let replicaId):
                guard let entry = entryOpt else { continue }
                
                ensureMapParents(root: snapshot, path: path, ts: Int(ts), replicaId: replicaId)
                
                let key = path.last ?? ""
                var parent: LDContainer
                
                do {
                    parent = try navigateToParent(path: path, forceCreate: true)
                } catch {
                    continue
                }
                
                switch parent {
                case .map(let m):
                    m.index[key] = entry
                case .array(let a):
                    a.entries[key] = entry
                }
                
            case .replace(let path, let entry, let ts, let replicaId):
                
                ensureMapParents(root: snapshot, path: path, ts: Int(ts), replicaId: replicaId)
                
                let key = path.last ?? ""
                var parent: LDContainer
                
                do {
                    parent = try navigateToParent(path: path, forceCreate: true)
                } catch {
                    continue
                }
                
                switch parent {
                case .map(let m):
                    m.index[key] = entry
                case .array(let a):
                    a.entries[key] = entry
                }
                ensureMapParents(root: snapshot, path: path, ts: ts, replicaId: replicaId)
                
                do {
                    parent = try navigateToParent(path: path, forceCreate: (op.self is Never) ? false : true)
                } catch {
                    // fallback: array element upsert
                    if path.count >= 3 {
                        let arrayPath = Array(path.dropLast(2))
                        let elemId = path[path.count - 2]
                        if let cont = getContainerAt(path: arrayPath), case .array(let a) = cont {
                            if a.entries[elemId] == nil {
                                a.entries[elemId] = LDEntry(
                                    id: elemId, key: elemId, type: .object, value: .map(LDMap()),
                                    meta: LDMeta(updatedAt: ts, version: 1, replicaId: replicaId, after: .some(nil))
                                )
                            }
                            if let p = try? navigateToParent(path: path, forceCreate: false) {
                                parent = p
                            } else { continue }
                        } else { continue }
                    } else { continue }
                }
                switch parent {
                case .map(let m): m.index[key] = entry
                case .array(let a): a.entries[key] = entry
                }
            }
        }
        
        // Notify listeners
        let affectedPaths = Set(ops.map { $0.path.joined(separator: ".") })
        let snapshotListeners = listeners

        for (subPath, cbs) in snapshotListeners {
            if affectedPaths.contains(where: { $0.hasPrefix(subPath) }) {
                let json = (try? navigate(path: subPath.isEmpty ? [] : subPath.split(separator: ".").map(String.init))).map { toAny($0) } ?? NSNull()
                cbs.forEach { $0(json) }
            }
        }
    }
    
    // MARK: - Query
    public struct QueryHandle {
        public let execute: () async -> Any?
        public let listen: (@escaping CRDTListener) async -> () -> Void
    }
    
    public func query(path: String? = nil) -> QueryHandle {
        let segments: [String]
        if let p = path, !p.isEmpty, p != "index" {
            segments = p.split(separator: ".").map(String.init)
        } else {
            segments = []
        }
        
        let execute: () async -> Any? = { [weak self] in
            guard let self else { return nil }
            return (try? self.navigate(path: segments)).map { toAny($0) }
        }
        
        let listen: (@escaping CRDTListener) async -> () -> Void = { [weak self] cb in
            guard let self else { return {} }
            let key = path ?? ""
            queue.sync {
                self.listeners[key, default: []].append(cb)
            }
            cb((try? self.navigate(path: segments)).map { toAny($0) } ?? NSNull())
            return { [weak self] in
                self?.listeners[key]?.removeAll { _ in true }  // simplified removal
            }
        }
        
        return QueryHandle(execute: execute, listen: listen)
    }
}

