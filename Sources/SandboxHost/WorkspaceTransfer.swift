import Foundation
import CryptoKit

enum WorkspaceTransferError: Error { case rejected }
struct FrozenWorkspaceTransfer {
    // A value snapshot, never a path to guest-writable storage.
    let files: [String: Data]
    let sha256: String
    // Keep payload capacity charged as long as any frozen value is retained.
    private let reservation: WorkspaceTransferReservation?
    let quota: WorkspaceGrantQuota?
    private let task: TaskQuotaLedger?
    private let workflow: WorkspaceWorkflowBinding?
    init(files: [String: Data], sha256: String, reservation: WorkspaceTransferReservation? = nil, quota: WorkspaceGrantQuota? = nil,
         task: TaskQuotaLedger? = nil, workflow: WorkspaceWorkflowBinding? = nil) {
        self.files = files; self.sha256 = sha256; self.reservation = reservation; self.quota = quota
        self.task = task; self.workflow = workflow
    }
    func belongs(to task: TaskQuotaLedger) -> Bool {
        self.task === task && workflow?.matches(task.workflow) == true
    }
}

/// Shared by receiving channels within one host budget domain. This measures
/// retained payload bytes, not Foundation allocator/parser overhead or RSS.
final class WorkspaceTransferBudget: @unchecked Sendable {
    struct Metrics {
        var used = 0, reserved = 0, committed = 0, peak = 0, peakUsed = 0, accepted = 0, released = 0, orphaned = 0
    }
    private let lock = NSLock()
    private let capacity: Int
    private let cumulativeLimit: Int
    fileprivate let retainCommitted: Bool
    private var state = Metrics()
    init(capacity: Int, cumulativeLimit: Int = Int.max, retainCommitted: Bool = false) {
        self.capacity = max(0, min(capacity, 128 * 1024 * 1024))
        self.cumulativeLimit = max(0, cumulativeLimit)
        self.retainCommitted = retainCommitted
    }
    var metrics: Metrics { lock.withLock { state } }
    fileprivate func reserve(_ bytes: Int) throws {
        try lock.withLock {
            guard bytes >= 0, bytes <= capacity - state.used - state.reserved - (retainCommitted ? state.committed : 0),
                  bytes <= cumulativeLimit - state.accepted - state.reserved else { throw WorkspaceTransferError.rejected }
            state.reserved += bytes
            state.peak = max(state.peak, state.used + state.reserved + (retainCommitted ? state.committed : 0))
        }
    }
    fileprivate func accept(_ bytes: Int) {
        lock.withLock {
            state.reserved -= bytes; state.used += bytes
            state.peakUsed = max(state.peakUsed, state.used + (retainCommitted ? state.committed : 0))
            state.accepted += min(bytes, Int.max - state.accepted)
        }
    }
    fileprivate func orphan(_ bytes: Int) { lock.withLock { state.orphaned += bytes } }
    fileprivate func commit(_ bytes: Int) {
        guard retainCommitted else { return }
        lock.withLock { state.used -= bytes; state.committed += bytes }
    }
    fileprivate func release(used: Int, reserved: Int) {
        lock.withLock {
            state.used -= used; state.reserved -= reserved
            state.released += min(used + reserved, Int.max - state.released)
        }
    }
}

final class WorkspaceTransferReservation {
    private let budgets: [WorkspaceTransferBudget]
    private var used = 0, reserved = 0
    private var committed = false
    init(_ budget: WorkspaceTransferBudget, additional: WorkspaceTransferBudget? = nil, task: WorkspaceTransferBudget? = nil) {
        var unique = [WorkspaceTransferBudget]()
        for candidate in [budget, additional, task].compactMap({ $0 }) where !unique.contains(where: { $0 === candidate }) { unique.append(candidate) }
        budgets = unique
    }
    func reserve(_ bytes: Int) throws {
        var acquired = [WorkspaceTransferBudget]()
        do {
            for budget in budgets { try budget.reserve(bytes); acquired.append(budget) }
        } catch {
            for budget in acquired { budget.release(used: 0, reserved: bytes) }
            throw error
        }
        reserved += bytes
    }
    func accept(_ bytes: Int) { for budget in budgets { budget.accept(bytes) }; reserved -= bytes; used += bytes }
    func commit() {
        guard !committed else { return }
        committed = true
        for budget in budgets { budget.commit(used) }
    }
    // Failed identity-safe cleanup must not pretend that disk capacity is free.
    func orphan(_ bytes: Int) { for budget in budgets { budget.orphan(bytes) }; used -= bytes }
    deinit { for budget in budgets { budget.release(used: committed && budget.retainCommitted ? 0 : used, reserved: reserved) } }
}
enum WorkspaceTransferWire {
    // Host-owned intersection. Wire declarations never select or enlarge limits.
    static func effectiveLimits(_ host: WorkspaceLimits) -> WorkspaceLimits {
        var value = WorkspaceLimits()
        value.entries = min(value.entries, host.entries)
        value.fileBytes = min(value.fileBytes, host.fileBytes)
        value.totalBytes = min(value.totalBytes, host.totalBytes)
        // Workspace depth counts directories; the channel permits 16 components.
        value.depth = min(15, host.depth)
        value.pathBytes = min(value.pathBytes, host.pathBytes)
        return value
    }
    static func register(_ path: String, limits: WorkspaceLimits,
                         paths: inout [String: String], files: Set<String>) throws {
        guard path.utf8.count <= limits.pathBytes else { throw WorkspaceTransferError.rejected }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count - 1 <= limits.depth else { throw WorkspaceTransferError.rejected }
        var prefix = ""
        for (index, component) in parts.enumerated() {
            let part = String(component)
            try WorkspaceStore.component(part)
            guard !WorkspaceStore.excluded(part) else { throw WorkspaceTransferError.rejected }
            prefix = prefix.isEmpty ? part : prefix + "/" + part
            let key = prefix.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if let previous = paths[key] {
                guard previous == prefix, index < parts.count - 1, !files.contains(previous) else { throw WorkspaceTransferError.rejected }
            } else {
                guard paths.count < limits.entries else { throw WorkspaceTransferError.rejected }
                paths[key] = prefix
            }
        }
    }
    @discardableResult static func preflight(_ files: [String: Data], limits host: WorkspaceLimits) throws -> Int {
        let limits = effectiveLimits(host)
        guard files.count <= limits.entries else { throw WorkspaceTransferError.rejected }
        var paths = [String: String](), seen = Set<String>(), total = 0
        for (path, data) in files {
            guard data.count <= limits.fileBytes, data.count <= limits.totalBytes - total else { throw WorkspaceTransferError.rejected }
            try register(path, limits: limits, paths: &paths, files: seen)
            seen.insert(path); total += data.count
        }
        return total
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func treeHash(_ files: [String:Data]) -> String {
        hash(Data(files.keys.sorted().map { "\($0)\0\(files[$0]!.count)\0\(hash(files[$0]!))\n" }.joined().utf8))
    }
    static func messages(_ files:[String:Data]) throws -> [Data] {
        var result=[Data]()
        func add(_ type:String,_ fields:[String:Any]=[:]) throws {
            var d=fields;d["v"]=1;d["type"]=type;d["seq"]=result.count
            result.append(try JSONSerialization.data(withJSONObject:d,options:[.sortedKeys]))
        }
        try add("begin",["count":files.count,"total":files.values.reduce(0){$0+$1.count}])
        for path in files.keys.sorted() {
            let data=files[path]!
            try add("file",["path":path,"size":data.count,"sha256":hash(data)])
            for offset in stride(from:0,to:data.count,by:4096) {
                try add("chunk",["offset":offset,"data":data.subdata(in:offset..<min(offset+4096,data.count)).base64EncodedString()])
            }
            try add("end")
        }
        try add("complete",["sha256":treeHash(files)])
        return result
    }
}
final class WorkspaceTransferReceiver {
    private let limits: WorkspaceLimits
    let budget: WorkspaceTransferBudget
    private let quota: WorkspaceGrantQuota?
    private let workflow: WorkspaceWorkflowBinding?
    let messageBytes: Int
    private var reservation: WorkspaceTransferReservation?
    init(limits: WorkspaceLimits = WorkspaceLimits(), budget: WorkspaceTransferBudget? = nil, quota: WorkspaceGrantQuota? = nil, workflow: WorkspaceWorkflowBinding? = nil) {
        self.quota = quota
        self.workflow = workflow ?? quota?.task?.workflow
        self.messageBytes = quota?.task?.messageBytes ?? quota?.messageBytes ?? 16384
        self.limits = quota?.limits(store: limits) ?? WorkspaceTransferWire.effectiveLimits(limits)
        self.budget = budget ?? WorkspaceTransferBudget(capacity: self.limits.totalBytes)
    }
    private(set) var poisoned=false
    private var sealed=false, started=false
    private var seq:Int64=0, count=0, total=0, received=0
    private var files=[String:Data](), paths=[String:String]()
    private var path:String?, size=0, digest="", data=Data()
    private(set) var acceptedBytes = 0
    func stop() { poisoned=true; sealed=false; files.removeAll();data=Data();path=nil;reservation=nil }
    func snapshot() throws -> FrozenWorkspaceTransfer {
        try workflow?.validate()
        guard sealed && !poisoned else { throw WorkspaceTransferError.rejected }
        return FrozenWorkspaceTransfer(files:files,sha256:WorkspaceTransferWire.treeHash(files),reservation:reservation,quota:quota,
                                       task:quota?.task,workflow:workflow)
    }
    func receive(_ bytes:Data) throws {
        do { try accept(bytes) } catch { stop(); throw WorkspaceTransferError.rejected }
    }
    private func accept(_ bytes:Data) throws {
        try workflow?.validate()
        guard !poisoned && !sealed, bytes.count <= messageBytes, let f=try RuntimeJSON.parse(bytes).object,
              f["v"] == .integer(1),f["seq"] == .integer(seq),let kind=f["type"]?.string else {throw WorkspaceTransferError.rejected}
        func fields(_ names:Set<String>) throws {
            guard Set(f.keys)==names.union(["v","type","seq"]) else {throw WorkspaceTransferError.rejected}
        }
        func number(_ name:String,_ max:Int) throws -> Int {
            guard let n=f[name]?.integer,n>=0,n<=max else {throw WorkspaceTransferError.rejected};return Int(n)
        }
        func hashField() throws -> String {
            guard let s=f["sha256"]?.string,s.utf8.count==64,s.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw WorkspaceTransferError.rejected};return s
        }
        switch kind {
        case "begin":
            try fields(["count","total"]);guard !started else {throw WorkspaceTransferError.rejected}
            count=try number("count",limits.entries);total=try number("total",limits.totalBytes);started=true
        case "file":
            try fields(["path","size","sha256"])
            guard started,path==nil,files.count<count,let p=f["path"]?.string else {throw WorkspaceTransferError.rejected}
            size=try number("size",limits.fileBytes);guard size<=total-received else {throw WorkspaceTransferError.rejected}
            try WorkspaceTransferWire.register(p, limits: limits, paths: &paths, files: Set(files.keys))
            digest=try hashField();path=p;data=Data()
        case "chunk":
            try fields(["offset","data"])
            guard path != nil,try number("offset",limits.fileBytes)==data.count,let text=f["data"]?.string,
                  !text.isEmpty, text.utf8.count <= 5464, text.utf8.count % 4 == 0 else {throw WorkspaceTransferError.rejected}
            let padding = text.hasSuffix("==") ? 2 : (text.hasSuffix("=") ? 1 : 0)
            let actual = text.utf8.count / 4 * 3 - padding
            guard actual > 0, actual <= 4096, actual <= size - data.count,
                  actual <= limits.fileBytes - data.count,
                  actual <= total - received - data.count,
                  actual <= limits.totalBytes - received - data.count else { throw WorkspaceTransferError.rejected }
            if reservation == nil { reservation = WorkspaceTransferReservation(budget, additional: quota?.memory, task: quota?.task?.memory) }
            // Reserve before base64 decoding and before retained payload growth.
            try reservation!.reserve(actual)
            guard let chunk=Data(base64Encoded:text),chunk.count==actual,chunk.base64EncodedString()==text else {throw WorkspaceTransferError.rejected}
            if let workflow { try workflow.append(chunk, to: &data) } else { data.append(chunk) }
            reservation!.accept(actual); acceptedBytes += actual
        case "end":
            try fields([])
            guard let p=path,data.count==size,WorkspaceTransferWire.hash(data)==digest else {throw WorkspaceTransferError.rejected}
            files[p]=data;received+=data.count;path=nil;data=Data()
        case "complete":
            try fields(["sha256"])
            guard started,path==nil,files.count==count,received==total,try hashField()==WorkspaceTransferWire.treeHash(files) else {throw WorkspaceTransferError.rejected}
            sealed=true
        default:throw WorkspaceTransferError.rejected
        }
        seq+=1;guard seq<=8192 else {throw WorkspaceTransferError.rejected}
    }
}

/// Owned exclusively by the VM queue. Not an App authorization or guest permit.
final class WorkspaceTransferFlow {
    let receiver: WorkspaceTransferReceiver
    private let workflow: WorkspaceWorkflowBinding?
    private let outbound:[Data]
    private var sent=0, hello=false
    var completed=false
    var cancelOnChunk=false
    var messageBytes: Int { receiver.messageBytes }
    init(files:[String:Data], limits: WorkspaceLimits = WorkspaceLimits(), budget: WorkspaceTransferBudget? = nil, quota: WorkspaceGrantQuota? = nil, workflow: WorkspaceWorkflowBinding? = nil) throws {
        self.workflow = workflow
        try workflow?.validate()
        let effective = quota?.limits(store: limits) ?? limits
        try WorkspaceTransferWire.preflight(files, limits: effective)
        receiver = WorkspaceTransferReceiver(limits: effective, budget: budget, quota: quota, workflow: workflow)
        outbound=try WorkspaceTransferWire.messages(files)
        guard outbound.allSatisfy({ $0.count <= receiver.messageBytes }) else { throw WorkspaceTransferError.rejected }
    }
    func receive(_ bytes:Data) throws -> Data? {
        do { try workflow?.validate() } catch { receiver.stop(); throw WorkspaceTransferError.rejected }
        guard !completed, bytes.count <= messageBytes, let f=try RuntimeJSON.parse(bytes).object else {receiver.stop();throw WorkspaceTransferError.rejected}
        if !hello {
            guard f==["v":.integer(1),"type":.string("ready")] else {throw WorkspaceTransferError.rejected}
            hello=true;sent=1;return outbound[0]
        }
        if sent<=outbound.count {
            guard f==["v":.integer(1),"type":.string("ack"),"seq":.integer(Int64(sent-1))] else {throw WorkspaceTransferError.rejected}
            if sent<outbound.count {let b=outbound[sent];sent+=1;return b}
            sent+=1;return nil
        }
        try receiver.receive(bytes)
        if f["type"] == .string("complete") { _ = try receiver.snapshot();completed=true }
        return nil
    }
}
