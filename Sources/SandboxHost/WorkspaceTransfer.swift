import CryptoKit
import Foundation

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
    init(
        files: [String: Data], sha256: String, reservation: WorkspaceTransferReservation? = nil,
        quota: WorkspaceGrantQuota? = nil,
        task: TaskQuotaLedger? = nil, workflow: WorkspaceWorkflowBinding? = nil
    ) {
        self.files = files
        self.sha256 = sha256
        self.reservation = reservation
        self.quota = quota
        self.task = task
        self.workflow = workflow
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
                bytes <= cumulativeLimit - state.accepted - state.reserved
            else { throw WorkspaceTransferError.rejected }
            state.reserved += bytes
            state.peak = max(state.peak, state.used + state.reserved + (retainCommitted ? state.committed : 0))
        }
    }
    fileprivate func accept(_ bytes: Int) {
        lock.withLock {
            state.reserved -= bytes
            state.used += bytes
            state.peakUsed = max(state.peakUsed, state.used + (retainCommitted ? state.committed : 0))
            state.accepted += min(bytes, Int.max - state.accepted)
        }
    }
    fileprivate func orphan(_ bytes: Int) { lock.withLock { state.orphaned += bytes } }
    fileprivate func commit(_ bytes: Int) {
        guard retainCommitted else { return }
        lock.withLock {
            state.used -= bytes
            state.committed += bytes
        }
    }
    fileprivate func release(used: Int, reserved: Int) {
        lock.withLock {
            state.used -= used
            state.reserved -= reserved
            state.released += min(used + reserved, Int.max - state.released)
        }
    }
}

final class WorkspaceTransferReservation {
    private let budgets: [WorkspaceTransferBudget]
    private var used = 0, reserved = 0
    private var committed = false
    init(
        _ budget: WorkspaceTransferBudget, additional: WorkspaceTransferBudget? = nil,
        task: WorkspaceTransferBudget? = nil
    ) {
        var unique = [WorkspaceTransferBudget]()
        for candidate in [budget, additional, task].compactMap({ $0 })
        where !unique.contains(where: { $0 === candidate }) { unique.append(candidate) }
        budgets = unique
    }
    func reserve(_ bytes: Int) throws {
        var acquired = [WorkspaceTransferBudget]()
        do {
            for budget in budgets {
                try budget.reserve(bytes)
                acquired.append(budget)
            }
        } catch {
            for budget in acquired { budget.release(used: 0, reserved: bytes) }
            throw error
        }
        reserved += bytes
    }
    func accept(_ bytes: Int) {
        for budget in budgets { budget.accept(bytes) }
        reserved -= bytes
        used += bytes
    }
    func commit() {
        guard !committed else { return }
        committed = true
        for budget in budgets { budget.commit(used) }
    }
    // Failed identity-safe cleanup must not pretend that disk capacity is free.
    func orphan(_ bytes: Int) {
        for budget in budgets { budget.orphan(bytes) }
        used -= bytes
    }
    deinit {
        for budget in budgets {
            budget.release(used: committed && budget.retainCommitted ? 0 : used, reserved: reserved)
        }
    }
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
    static func register(
        _ path: String, limits: WorkspaceLimits,
        paths: inout [String: String], files: Set<String>
    ) throws {
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
                guard previous == prefix, index < parts.count - 1, !files.contains(previous) else {
                    throw WorkspaceTransferError.rejected
                }
            } else {
                guard paths.count < limits.entries else { throw WorkspaceTransferError.rejected }
                paths[key] = prefix
            }
        }
    }
    @discardableResult static func preflight(_ files: [String: Data], limits host: WorkspaceLimits) throws -> Int {
        let limits = effectiveLimits(host)
        guard files.count <= limits.entries else { throw WorkspaceTransferError.rejected }
        var paths = [String: String]()
        var seen = Set<String>()
        var total = 0
        for (path, data) in files {
            guard data.count <= limits.fileBytes, data.count <= limits.totalBytes - total else {
                throw WorkspaceTransferError.rejected
            }
            try register(path, limits: limits, paths: &paths, files: seen)
            seen.insert(path)
            total += data.count
        }
        return total
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func treeHash(_ files: [String: Data]) -> String {
        hash(Data(files.keys.sorted().map { "\($0)\0\(files[$0]!.count)\0\(hash(files[$0]!))\n" }.joined().utf8))
    }
    static func messages(_ files: [String: Data]) throws -> [Data] {
        var result = [Data]()
        func add(_ type: String, _ fields: [String: Any] = [:]) throws {
            var d = fields
            d["v"] = 1
            d["type"] = type
            d["seq"] = result.count
            result.append(try JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]))
        }
        try add("begin", ["count": files.count, "total": files.values.reduce(0) { $0 + $1.count }])
        for path in files.keys.sorted() {
            let data = files[path]!
            try add("file", ["path": path, "size": data.count, "sha256": hash(data)])
            for offset in stride(from: 0, to: data.count, by: 4096) {
                try add(
                    "chunk",
                    [
                        "offset": offset,
                        "data": data.subdata(in: offset..<min(offset + 4096, data.count)).base64EncodedString(),
                    ])
            }
            try add("end")
        }
        try add("complete", ["sha256": treeHash(files)])
        return result
    }
}
final class WorkspaceTransferReceiver {
    private let lock = NSLock()
    private let limits: WorkspaceLimits
    let budget: WorkspaceTransferBudget
    private let quota: WorkspaceGrantQuota?
    private let task: TaskQuotaLedger?
    let effectWorkflow: WorkspaceWorkflowBinding
    let messageBytes: Int
    private var reservation: WorkspaceTransferReservation?
    private var poisonedValue = false, sealed = false, started = false
    private var seq: Int64 = 0, count = 0, total = 0, received = 0
    private var files = [String: Data](), paths = [String: String]()
    private var path: String?, size = 0, offset = 0, digest = "", data = Data()
    private var accepted = 0
    private enum Prepared {
        case begin(Int, Int)
        case file(String, Int, String, [String: String], Data)
        case chunk(Data)
        case end([String: Data], Int)
        case complete
    }
    private var prepared: Prepared?
    private var preparedSequence: Int64 = -1
    private var preparedSnapshot: FrozenWorkspaceTransfer?
    private var acceptedToSettle = 0
    private var previousPaths: [String: String]?
    private var previousFiles: [String: Data]?
    // Deterministic tests pause before workflow/lifecycle ownership, never inside.
    var beforeInputEffect: (() -> Void)?

    init(
        limits: WorkspaceLimits = WorkspaceLimits(), budget: WorkspaceTransferBudget? = nil,
        quota: WorkspaceGrantQuota? = nil, workflow: WorkspaceWorkflowBinding? = nil
    ) {
        self.quota = quota
        task = quota?.task
        effectWorkflow = workflow ?? quota?.task?.workflow ?? (try! WorkspaceExportCancellation().binding())
        messageBytes = quota?.task?.messageBytes ?? quota?.messageBytes ?? 16384
        self.limits = quota?.limits(store: limits) ?? WorkspaceTransferWire.effectiveLimits(limits)
        self.budget = budget ?? WorkspaceTransferBudget(capacity: self.limits.totalBytes)
    }
    var poisoned: Bool { lock.withLock { poisonedValue } }
    var acceptedBytes: Int { lock.withLock { accepted } }
    var isComplete: Bool { lock.withLock { sealed && !poisonedValue } }
    func stop() {
        lock.lock()
        poisonedValue = true
        sealed = false
        let retained = (files, data, reservation, preparedSnapshot)
        files.removeAll()
        data = Data()
        path = nil
        reservation = nil
        preparedSnapshot = nil
        lock.unlock()
        withExtendedLifetime(retained) {}
    }
    func snapshot() throws -> FrozenWorkspaceTransfer {
        guard case .snapshot(let result) = try WorkspacePreparedEffect.snapshot(self).perform() else {
            throw WorkspaceTransferError.rejected
        }
        return result
    }
    func receive(_ bytes: Data) throws {
        do { try WorkspacePreparedEffect.receive(self, bytes).perform() } catch {
            stop()
            throw WorkspaceTransferError.rejected
        }
    }
    func acquireEffect() { lock.lock() }
    func releaseEffect() {
        let retained = (prepared, preparedSnapshot, previousPaths, previousFiles)
        prepared = nil
        preparedSnapshot = nil
        preparedSequence = -1
        previousPaths = nil
        previousFiles = nil
        lock.unlock()
        withExtendedLifetime(retained) {}
    }
    func validateEffectLocked() throws {
        if let quota {
            guard let run = effectWorkflow.run, run.handle === quota.handle,
                run.snapshot.grantSnapshotID == quota.snapshotID
            else { throw WorkspaceTransferError.rejected }
            if let task { guard effectWorkflow.matches(task.workflow) else { throw WorkspaceTransferError.rejected } }
        } else if effectWorkflow.run != nil {
            throw WorkspaceTransferError.rejected
        }
        guard !poisonedValue else { throw WorkspaceTransferError.rejected }
    }
    func prepareSnapshotLocked() throws {
        guard sealed, !poisonedValue else { throw WorkspaceTransferError.rejected }
        preparedSnapshot = FrozenWorkspaceTransfer(
            files: files, sha256: WorkspaceTransferWire.treeHash(files),
            reservation: reservation, quota: quota, task: task, workflow: effectWorkflow)
    }
    func snapshotEffectLocked() throws -> FrozenWorkspaceTransfer {
        guard sealed, !poisonedValue, let result = preparedSnapshot else { throw WorkspaceTransferError.rejected }
        return result
    }
    func prepareEffectLocked(_ bytes: Data) throws {
        guard !poisonedValue, !sealed, seq < 8192, bytes.count <= messageBytes,
            let f = try RuntimeJSON.parse(bytes).object, f["v"] == .integer(1), f["seq"] == .integer(seq),
            let kind = f["type"]?.string
        else { throw WorkspaceTransferError.rejected }
        func fields(_ names: Set<String>) throws {
            guard Set(f.keys) == names.union(["v", "type", "seq"]) else { throw WorkspaceTransferError.rejected }
        }
        func number(_ name: String, _ max: Int) throws -> Int {
            guard let n = f[name]?.integer, n >= 0, n <= max else { throw WorkspaceTransferError.rejected }
            return Int(n)
        }
        func hashField() throws -> String {
            guard let s = f["sha256"]?.string, s.utf8.count == 64,
                s.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw WorkspaceTransferError.rejected }
            return s
        }
        preparedSequence = seq
        switch kind {
        case "begin":
            try fields(["count", "total"])
            guard !started else { throw WorkspaceTransferError.rejected }
            prepared = .begin(try number("count", limits.entries), try number("total", limits.totalBytes))
        case "file":
            try fields(["path", "size", "sha256"])
            guard started, path == nil, files.count < count, let p = f["path"]?.string else {
                throw WorkspaceTransferError.rejected
            }
            let bytes = try number("size", limits.fileBytes)
            guard bytes <= total - received else { throw WorkspaceTransferError.rejected }
            previousPaths = paths
            var nextPaths = paths
            try WorkspaceTransferWire.register(p, limits: limits, paths: &nextPaths, files: Set(files.keys))
            let hash = try hashField()
            if reservation == nil {
                reservation = WorkspaceTransferReservation(budget, additional: quota?.memory, task: task?.memory)
            }
            // Charge capacity BEFORE allocating a fixed-size file buffer. Each
            // final chunk copies at most 4096 bytes without growing/copying it.
            try reservation!.reserve(bytes)
            prepared = .file(p, bytes, hash, nextPaths, Data(count: bytes))
        case "chunk":
            try fields(["offset", "data"])
            guard path != nil, try number("offset", limits.fileBytes) == offset,
                let text = f["data"]?.string, !text.isEmpty, text.utf8.count <= 5464,
                text.utf8.count % 4 == 0
            else { throw WorkspaceTransferError.rejected }
            let padding = text.hasSuffix("==") ? 2 : (text.hasSuffix("=") ? 1 : 0)
            let actual = text.utf8.count / 4 * 3 - padding
            guard actual > 0, actual <= 4096, actual <= size - offset,
                actual <= limits.fileBytes - offset, actual <= total - received - offset,
                actual <= limits.totalBytes - received - offset,
                let chunk = Data(base64Encoded: text), chunk.count == actual,
                chunk.base64EncodedString() == text
            else { throw WorkspaceTransferError.rejected }
            prepared = .chunk(chunk)
        case "end":
            try fields([])
            guard let p = path, offset == size, WorkspaceTransferWire.hash(data) == digest else {
                throw WorkspaceTransferError.rejected
            }
            previousFiles = files
            var nextFiles = files
            nextFiles[p] = data
            prepared = .end(nextFiles, received + size)
        case "complete":
            try fields(["sha256"])
            guard started, path == nil, files.count == count, received == total,
                try hashField() == WorkspaceTransferWire.treeHash(files)
            else { throw WorkspaceTransferError.rejected }
            prepared = .complete
        default: throw WorkspaceTransferError.rejected
        }
        beforeInputEffect?()
    }
    func commitEffectLocked() throws {
        guard !poisonedValue, !sealed, preparedSequence == seq, let prepared else {
            throw WorkspaceTransferError.rejected
        }
        switch prepared {
        case .begin(let count, let total):
            self.count = count
            self.total = total
            started = true
        case .file(let path, let size, let digest, let paths, let storage):
            self.path = path
            self.size = size
            self.digest = digest
            self.paths = paths
            data = storage
            offset = 0
        case .chunk(let chunk):
            // The unique buffer has already been fully allocated and charged.
            data.withUnsafeMutableBytes { target in
                chunk.withUnsafeBytes { source in
                    target.baseAddress!.advanced(by: offset).copyMemory(
                        from: source.baseAddress!, byteCount: chunk.count)
                }
            }
            offset += chunk.count
            accepted += chunk.count
            acceptedToSettle = chunk.count
        case .end(let files, let received):
            self.files = files
            self.received = received
            path = nil
            data = Data()
            offset = 0
        case .complete: sealed = true
        }
        seq += 1
    }
    func settleEffectLocked() {
        if acceptedToSettle > 0 {
            reservation!.accept(acceptedToSettle)
            acceptedToSettle = 0
        }
    }
}

/// Owned exclusively by the VM queue. Not an App authorization or guest permit.
final class WorkspaceTransferFlow {
    let receiver: WorkspaceTransferReceiver
    private let workflow: WorkspaceWorkflowBinding?
    private let outbound: [Data]
    private var sent = 0, hello = false
    var completed: Bool { receiver.isComplete }
    var cancelOnChunk = false
    var messageBytes: Int { receiver.messageBytes }
    init(
        files: [String: Data], limits: WorkspaceLimits = WorkspaceLimits(), budget: WorkspaceTransferBudget? = nil,
        quota: WorkspaceGrantQuota? = nil, workflow: WorkspaceWorkflowBinding? = nil
    ) throws {
        self.workflow = workflow
        try workflow?.validate()
        let effective = quota?.limits(store: limits) ?? limits
        try WorkspaceTransferWire.preflight(files, limits: effective)
        receiver = WorkspaceTransferReceiver(limits: effective, budget: budget, quota: quota, workflow: workflow)
        outbound = try WorkspaceTransferWire.messages(files)
        guard outbound.allSatisfy({ $0.count <= receiver.messageBytes }) else { throw WorkspaceTransferError.rejected }
    }
    func receive(_ bytes: Data) throws -> Data? {
        do { try workflow?.validate() } catch {
            receiver.stop()
            throw WorkspaceTransferError.rejected
        }
        guard !completed, bytes.count <= messageBytes, let f = try RuntimeJSON.parse(bytes).object else {
            receiver.stop()
            throw WorkspaceTransferError.rejected
        }
        if !hello {
            guard f == ["v": .integer(1), "type": .string("ready")] else { throw WorkspaceTransferError.rejected }
            hello = true
            sent = 1
            return outbound[0]
        }
        if sent <= outbound.count {
            guard f == ["v": .integer(1), "type": .string("ack"), "seq": .integer(Int64(sent - 1))] else {
                throw WorkspaceTransferError.rejected
            }
            if sent < outbound.count {
                let b = outbound[sent]
                sent += 1
                return b
            }
            sent += 1
            return nil
        }
        try receiver.receive(bytes)
        if f["type"] == .string("complete") { _ = try receiver.snapshot() }
        return nil
    }
}
