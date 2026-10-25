import Foundation
import CryptoKit
import Darwin

public enum WorkspaceError: Error, Equatable {
    case rejected(String)
    case blockedPlatform(String)
    case io(String, Int32)
    case mutated
    case cancelled
    case foreignSnapshot
    case staleReview
    /// Rename succeeded; publication may have occurred despite verification failure.
    case committedUnverified(String)
}

public struct WorkspaceLimits {
    public var entries: Int = 1_000
    public var fileBytes: Int = 4 * 1_024 * 1_024
    public var totalBytes: Int = 16 * 1_024 * 1_024
    public var depth: Int = 16
    public var pathBytes: Int = 1_024
    public var previewBytes: Int = 4_096
    public init() {}
}

/// One host filesystem action's cancellation fence, not run/grant authority.
/// Cancellation is irreversible. The concrete exclusive rename shares its lock;
/// cancellation after that syscall cannot retract or delete committed files.
public final class WorkspaceExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var generation: UInt64 = 1
    private let owner = UUID()
    public init() {}
    public func cancel() { lock.withLock { if !stopped { stopped = true; generation += 1 } } }
    public var isCancelled: Bool { lock.withLock { stopped } }
    func binding() throws -> WorkspaceWorkflowBinding {
        try lock.withLock {
            guard !stopped else { throw WorkspaceError.cancelled }
            return WorkspaceWorkflowBinding(gate: self, owner: owner, generation: generation)
        }
    }
    func acquireEffect() { lock.lock() }
    func releaseEffect() { lock.unlock() }
    func validateLocked(_ binding: WorkspaceWorkflowBinding) throws {
        guard binding.gate === self, binding.owner == owner, binding.generation == generation, !stopped else { throw WorkspaceError.cancelled }
        if let run = binding.run { guard run.matches(binding) else { throw WorkspaceError.foreignSnapshot } }
    }
}

struct WorkspaceWorkflowBinding: @unchecked Sendable {
    let gate: WorkspaceExportCancellation
    let owner: UUID
    let generation: UInt64
    let run: WorkspaceRunBinding?
    init(gate: WorkspaceExportCancellation, owner: UUID, generation: UInt64, run: WorkspaceRunBinding? = nil) {
        self.gate = gate; self.owner = owner; self.generation = generation; self.run = run
    }
    func validate() throws { try WorkspacePreparedEffect.validate(self).perform() }
    func matches(_ other: WorkspaceWorkflowBinding) -> Bool {
        gate === other.gate && owner == other.owner && generation == other.generation && run === other.run
    }
    func cancel() { gate.cancel() }
    func bound(to run: WorkspaceRunBinding) throws -> Self {
        guard self.run == nil || self.run === run, owner == run.workflowOwner, generation == run.workflowGeneration else {
            throw WorkspaceError.foreignSnapshot
        }
        return Self(gate: gate, owner: owner, generation: generation, run: run)
    }
}

/// Opaque, process-local handle; not a guest capability or a persisted authorization.
public struct WorkspaceSnapshotID: Hashable, Sendable {
    fileprivate let value = UUID()
    // Host-only binding when constructing the immutable RunGrant; not a lookup
    // selected from guest JSON and not an execution capability.
    package var grantSnapshotID: UUID { value }
}
public struct WorkspaceSnapshot: Sendable {
    public let id: WorkspaceSnapshotID
    public let workingDirectory: String
    public let manifest: [WorkspaceManifestEntry]
    public let exclusions: [String]
}
public struct WorkspaceManifestEntry: Equatable, Sendable {
    public let path: String
    public let directory: Bool
    public let bytes: Int
    public let sha256: String?
}
public enum WorkspacePreview: Equatable, Sendable {
    case text(String)
    case noPreview(String)
}
public struct WorkspaceChange: Sendable {
    public enum Kind: String, Sendable { case add, change, delete }
    public let path: String
    public let kind: Kind
    public let before: WorkspacePreview?
    public let after: WorkspacePreview?
}
public struct WorkspaceReview: Sendable {
    public let sha256: String
    public let changes: [WorkspaceChange]
    public let manifest: [WorkspaceManifestEntry]
    public let exclusions: [String]
    fileprivate let owner: UUID
    fileprivate let snapshot: WorkspaceSnapshotID
    fileprivate let tree: WorkspaceTree
    fileprivate let task: TaskQuotaLedger?
}

final class WorkspaceFD {
    let value: Int32
    init(_ value: Int32) throws {
        guard value >= 0 else { throw WorkspaceError.io("open", errno) }
        self.value = value
    }
    deinit { close(value) }
}
/// Tracks only exclusively created nodes through adoption/rename. No recursive
/// path deletion: replacements and unknown children are preserved and charged.
private final class WorkspaceDiskWrite {
    private struct Node {
        let parent: WorkspaceFD, name: String, fd: WorkspaceFD, directory: Bool
        var bytes = 0
    }
    private var nodes = [Node]()
    private let reservation: WorkspaceTransferReservation
    private var finished = false
    init(budget: WorkspaceTransferBudget, bytes: Int, quota: WorkspaceGrantQuota? = nil) throws {
        try quota?.task?.claimMaterialization()
        reservation = WorkspaceTransferReservation(budget, additional: quota?.disk, task: quota?.task?.disk)
        try reservation.reserve(bytes)
    }
    @discardableResult func track(_ parent: WorkspaceFD, _ name: String, _ fd: WorkspaceFD, directory: Bool) -> Int {
        nodes.append(Node(parent: parent, name: name, fd: fd, directory: directory))
        return nodes.count - 1
    }
    func wrote(_ bytes: Int, at index: Int) { nodes[index].bytes += bytes; reservation.accept(bytes) }
    func finish() { guard !finished else { return }; finished = true; reservation.commit() }
    deinit {
        guard !finished else { return }
        // These descriptors refer solely to our newly created directories.
        for node in nodes where node.directory { _ = fchmod(node.fd.value, 0o700) }
        for node in nodes.reversed() {
            var named = stat(), opened = stat()
            let ours = fstatat(node.parent.value, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0
                && fstat(node.fd.value, &opened) == 0
                && named.st_dev == opened.st_dev && named.st_ino == opened.st_ino
            if !ours || unlinkat(node.parent.value, node.name, node.directory ? AT_REMOVEDIR : 0) != 0 {
                reservation.orphan(node.bytes)
            }
        }
    }
}

private struct WorkspaceIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    init(_ s: stat) { device = s.st_dev; inode = s.st_ino }
}
private struct WorkspaceStamp: Equatable {
    let identity: WorkspaceIdentity
    let size: off_t
    let links: nlink_t
    let mode: mode_t
    let mt: Int; let mn: Int; let ct: Int; let cn: Int
    init(_ s: stat) {
        identity = WorkspaceIdentity(s); size = s.st_size; links = s.st_nlink; mode = s.st_mode
        mt = s.st_mtimespec.tv_sec; mn = s.st_mtimespec.tv_nsec
        ct = s.st_ctimespec.tv_sec; cn = s.st_ctimespec.tv_nsec
    }
}
private struct WorkspaceNode: Equatable, Sendable {
    let data: Data? // nil represents an empty or nonempty directory
    var digest: String? { data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } }
}
fileprivate struct WorkspaceTree: Equatable, Sendable {
    fileprivate var nodes: [String: WorkspaceNode] = [:]
    var exclusions: [String] = []
    var digest: String {
        WorkspaceTransferWire.hash(Data(manifest.map { "\($0.path)\0\($0.directory)\0\($0.bytes)\0\($0.sha256 ?? "directory")\n" }.joined().utf8))
    }
    var manifest: [WorkspaceManifestEntry] {
        nodes.keys.sorted().map { path in
            let node = nodes[path]!
            return WorkspaceManifestEntry(path: path, directory: node.data == nil,
                                          bytes: node.data?.count ?? 0, sha256: node.digest)
        }
    }
}
fileprivate struct WorkspaceRecord {
    let baseline: WorkspaceTree
    let source: WorkspaceFD
    let sourcePath: String
    let work: WorkspaceFD
    let workPath: String
}

/// Synchronous trusted-host-only API. Serialize access; no guest JSON entry point.
/// Baseline truth stays private in memory and is also stored read-only on disk.
public final class WorkspaceStore {
    private let root: WorkspaceFD
    private let rootPath: String
    private let limits: WorkspaceLimits
    // Host-owned budget domains; channels/stores may explicitly share these.
    var transferMemoryBudget: WorkspaceTransferBudget
    var transferDiskBudget: WorkspaceTransferBudget
    private let owner = UUID()
    private let effectLock = NSRecursiveLock()
    private var records: [WorkspaceSnapshotID: WorkspaceRecord] = [:]
    private var transferQuotas: [WorkspaceSnapshotID: WorkspaceGrantQuota] = [:]
    private var transferBindings: [WorkspaceSnapshotID: WorkspaceRunBinding] = [:]
    private let cancelled: () -> Bool
    private let cancellation: WorkspaceExportCancellation

    // Deterministic trusted-host test observations, outside the commit mutex.
    enum ExportBoundary { case beforeRename, afterRename }
    var exportBoundary: ((ExportBoundary) -> Void)?
    var didWriteTransferChunk: ((Int) -> Void)?
    // Test observation only, outside cancellation ownership and before syscall.
    var beforeTransferWrite: (() -> Void)?
    var beforeTransferAdoption: (() -> Void)?
    // Host instrumentation also permits deterministic mutation checks with real files.
    private let didReadChunk: ((String) throws -> Void)?

    public init(newRoot: String, limits: WorkspaceLimits = WorkspaceLimits(),
                cancelled: @escaping () -> Bool = { false },
                cancellation: WorkspaceExportCancellation = WorkspaceExportCancellation(),
                didReadChunk: ((String) throws -> Void)? = nil) throws {
        guard limits.entries > 0, limits.entries <= 10_000,
              limits.fileBytes > 0, limits.fileBytes <= 64 * 1_024 * 1_024,
              limits.totalBytes > 0, limits.totalBytes <= 128 * 1_024 * 1_024,
              limits.depth > 0, limits.depth <= 64, limits.pathBytes > 0,
              limits.pathBytes <= 4_096, limits.previewBytes >= 0,
              limits.previewBytes <= 65_536 else { throw WorkspaceError.rejected("limits") }
        self.limits = limits; self.cancelled = cancelled; self.didReadChunk = didReadChunk
        self.cancellation = cancellation
        transferMemoryBudget = WorkspaceTransferBudget(capacity: limits.totalBytes)
        transferDiskBudget = WorkspaceTransferBudget(capacity: limits.totalBytes)
        let (parent, name) = try Self.parent(newRoot)
        root = try Self.makeDirectory(parent, name)
        rootPath = newRoot
        try Self.verifyPath(newRoot, root)
    }

    public func importTree(from sourcePath: String) throws -> WorkspaceSnapshot {
        effectLock.lock(); defer { effectLock.unlock() }
        try checkpoint()
        try validateBindings()
        let source = try Self.openDirectory(sourcePath)
        try Self.disjoint(source, root)
        let tree = try stableScan(source)
        try validateBindings()
        try Self.verifyPath(sourcePath, source)
        let id = WorkspaceSnapshotID()
        let name = id.value.uuidString
        let area = try Self.makeDirectory(root, name)
        let baseline = try Self.makeDirectory(area, "baseline")
        let work = try Self.makeDirectory(area, "working")
        let validate = {
            try self.validateBindings()
            try Self.verifyPath(sourcePath, source)
            try Self.verifyNamed(self.root, name, area)
            try Self.verifyNamed(area, "baseline", baseline)
            try Self.verifyNamed(area, "working", work)
        }
        try materialize(tree, into: baseline, readOnly: true, validate: validate)
        try materialize(tree, into: work, readOnly: false, validate: validate)
        guard try stableScan(source) == tree else { throw WorkspaceError.mutated }
        try validate()
        records[id] = WorkspaceRecord(baseline: tree, source: source, sourcePath: sourcePath, work: work, workPath: rootPath + "/" + name + "/working")
        return WorkspaceSnapshot(id: id, workingDirectory: rootPath + "/" + name + "/working",
                                 manifest: tree.manifest, exclusions: tree.exclusions)
    }

    // Internal transport fixture seam; no public App approval fallback.
    func transferFiles(_ id: WorkspaceSnapshotID) throws -> [String: Data] {
        effectLock.lock(); defer { effectLock.unlock() }
        guard let record = records[id] else { throw WorkspaceError.foreignSnapshot }
        try validateBindings()
        let tree = try stableScan(record.work)
        guard tree.exclusions.isEmpty else { throw WorkspaceError.rejected("excluded transfer entries") }
        let files = tree.nodes.compactMapValues { $0.data }
        for (path, node) in tree.nodes where node.data == nil {
            guard files.keys.contains(where: { $0.hasPrefix(path + "/") }) else {
                throw WorkspaceError.rejected("empty directory transfer unsupported")
            }
        }
        try validateBindings()
        return files
    }

    func transferFlow(files: [String: Data]) throws -> WorkspaceTransferFlow {
        effectLock.lock(); defer { effectLock.unlock() }
        // Legacy synthetic checks only. A bound store cannot fall back to this.
        guard transferQuotas.isEmpty else { throw WorkspaceTransferError.rejected }
        return try WorkspaceTransferFlow(files: files, limits: limits, budget: transferMemoryBudget)
    }

    func bindTransferQuota(_ quota: WorkspaceGrantQuota, for id: WorkspaceSnapshotID) throws {
        effectLock.lock(); defer { effectLock.unlock() }
        guard records[id] != nil, id.value == quota.snapshotID else { throw WorkspaceError.foreignSnapshot }
        if let existing = transferQuotas[id], existing !== quota { throw WorkspaceTransferError.rejected }
        try quota.bindWorkspace(storeOwner: owner, snapshot: id, workflow: cancellation.binding())
        guard let binding = quota.workspaceBinding else { throw WorkspaceError.foreignSnapshot }
        transferBindings[id] = binding
        transferQuotas[id] = quota
    }

    func transferFlow(for id: WorkspaceSnapshotID, channelLimits: WorkspaceLimits = WorkspaceLimits()) throws -> WorkspaceTransferFlow {
        effectLock.lock(); defer { effectLock.unlock() }
        guard let quota = transferQuotas[id] else { throw WorkspaceTransferError.rejected }
        try quota.beginTransfer()
        return try WorkspaceTransferFlow(files: transferFiles(id), limits: quota.limits(store: limits, channel: channelLimits), budget: transferMemoryBudget, quota: quota, workflow: workspaceBinding(for: id))
    }

    /// Actual trusted-host task creation. Repeat calls return the SAME ledger;
    /// different limits, foreign owners and late creation are rejected.
    func createTransferTask(for id: WorkspaceSnapshotID, limits taskLimits: WorkspaceTaskLimits) throws -> TaskQuotaLedger {
        effectLock.lock(); defer { effectLock.unlock() }
        guard records[id] != nil, let quota = transferQuotas[id] else { throw WorkspaceTransferError.rejected }
        return try quota.createTask(storeOwner: owner, limits: taskLimits, store: limits, workflow: workspaceBinding(for: id))
    }

    // Receive bytes are already frozen by the queue-owned receiver. Independently
    // validate, exclusively materialize in quarantine, scan, then switch the handle.
    // No mutable guest path, chmod promise or incoming identifier is authority.
    func acceptTransfer(_ result: FrozenWorkspaceTransfer, for id: WorkspaceSnapshotID) throws -> String {
        effectLock.lock(); defer { effectLock.unlock() }
        guard let record = records[id] else { throw WorkspaceError.foreignSnapshot }
        try checkpoint()
        // Do not serialize/redecode or allocate WorkspaceNodes until the entire
        // frozen manifest (including inferred directories) fits this host store.
        let quota = transferQuotas[id]
        guard result.quota === quota else { throw WorkspaceTransferError.rejected }
        if let task = quota?.task {
            guard result.belongs(to: task) else { throw WorkspaceTransferError.rejected }
            try task.workflow.validate()
        }
        let effective = quota?.limits(store: limits) ?? limits
        let byteCount = try WorkspaceTransferWire.preflight(result.files, limits: effective)
        guard WorkspaceTransferWire.treeHash(result.files) == result.sha256 else { throw WorkspaceError.mutated }
        try checkpoint(); try validateBindings()
        let writing = try WorkspaceDiskWrite(budget: transferDiskBudget, bytes: byteCount, quota: quota)
        var tree = WorkspaceTree()
        for (path, data) in result.files {
            let parts = path.split(separator: "/").map(String.init)
            for n in 1..<parts.count { tree.nodes[parts.prefix(n).joined(separator: "/")] = WorkspaceNode(data: nil) }
            tree.nodes[path] = WorkspaceNode(data: data)
        }
        let workflow = try workspaceBinding(for: id)
        let name = "quarantine-" + UUID().uuidString
        let quarantine = try makeEffectDirectory(root, name, workflow: workflow)
        writing.track(root, name, quarantine, directory: true)
        let validate = { try self.validateBindings(); try Self.verifyNamed(self.root, name, quarantine) }
        try materialize(tree, into: quarantine, readOnly: true, writing: writing, workflow: workflow, transferLimits: effective, validate: validate)
        guard try stableScan(quarantine) == tree else { throw WorkspaceError.mutated }
        try checkpoint(); try validate()
        let path = rootPath + "/" + name
        beforeTransferAdoption?()
        let adopted = WorkspaceRecord(baseline: record.baseline, source: record.source, sourcePath: record.sourcePath, work: quarantine, workPath: path)
        try WorkspacePreparedEffect.adopt(WorkspacePreparedAdoption(store: self, snapshot: id, previous: record, next: adopted, workflow: workflow)).perform()
        writing.finish()
        return path
    }

    public func review(_ id: WorkspaceSnapshotID) throws -> WorkspaceReview {
        effectLock.lock(); defer { effectLock.unlock() }
        guard let record = records[id] else { throw WorkspaceError.foreignSnapshot }
        try validateBindings()
        let current = try stableScan(record.work)
        try validateBindings()
        return WorkspaceReview(sha256: current.digest, changes: changes(record.baseline, current), manifest: current.manifest,
                               exclusions: current.exclusions, owner: owner, snapshot: id, tree: current, task: transferQuotas[id]?.task)
    }

    public func originalChanges(_ id: WorkspaceSnapshotID) throws -> [WorkspaceChange] {
        effectLock.lock(); defer { effectLock.unlock() }
        guard let record = records[id] else { throw WorkspaceError.foreignSnapshot }
        try Self.verifyPath(record.sourcePath, record.source)
        let current = try stableScan(record.source)
        try Self.verifyPath(record.sourcePath, record.source)
        return changes(record.baseline, current)
    }

    /// Explicit host action only. No overwrite/backwrite option exists.
    public func exportReviewed(_ review: WorkspaceReview, toNewDirectory destination: String) throws {
        try exportReviewed(review, toNewDirectory: destination, action: nil)
    }
    private func exportReviewed(_ review: WorkspaceReview, toNewDirectory destination: String,
                                action: WorkspaceExportCancellation?) throws {
        effectLock.lock(); defer { effectLock.unlock() }
        guard review.owner == owner, let record = records[review.snapshot] else { throw WorkspaceError.foreignSnapshot }
        guard review.task === transferQuotas[review.snapshot]?.task else { throw WorkspaceError.staleReview }
        try checkpoint(action)
        let workflow = try action.map { try $0.binding() } ?? workspaceBinding(for: review.snapshot)
        if action == nil { try review.task?.workflow.validate() }
        _ = try Self.pathParts(destination)
        for record in records.values {
            if destination == record.sourcePath || destination.hasPrefix(record.sourcePath + "/") {
                throw WorkspaceError.rejected("source destination")
            }
        }
        try validateBindings()
        let (parent, name) = try Self.parent(destination)
        try permittedDestination(parent)
        var existing = stat()
        if fstatat(parent.value, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
            throw WorkspaceError.rejected("destination exists or is inaccessible")
        }
        let exportTree = try stableScan(record.work, action: action)
        guard exportTree.exclusions.isEmpty, review.tree.exclusions.isEmpty else {
            throw WorkspaceError.rejected("excluded working entries require selection")
        }
        guard exportTree == review.tree else { throw WorkspaceError.staleReview }
        try validateBindings()
        guard try Self.identity(parent) == Self.identity(Self.parent(destination).0) else { throw WorkspaceError.mutated }
        let stageName = ".workspace-stage-" + UUID().uuidString
        let quota = transferQuotas[review.snapshot]
        let effective = quota?.limits(store: limits) ?? limits
        let writing = try WorkspaceDiskWrite(budget: transferDiskBudget, bytes: materializationBytes(review.tree, transferLimits: effective), quota: quota)
        let stage = try makeEffectDirectory(parent, stageName, workflow: workflow)
        writing.track(parent, stageName, stage, directory: true)
        // Rollback touches only retained, exclusively created node identities.
        let validate = {
            try self.validateBindings()
            guard try Self.identity(parent) == Self.identity(Self.parent(destination).0) else { throw WorkspaceError.mutated }
            try self.permittedDestination(parent)
            try Self.verifyNamed(parent, stageName, stage)
        }
        try materialize(review.tree, into: stage, readOnly: false, writing: writing, action: action, workflow: workflow, transferLimits: effective, validate: validate)
        let stagedTree = try stableScan(stage, action: action)
        let latestWork = try stableScan(record.work, action: action)
        guard latestWork.exclusions.isEmpty else { throw WorkspaceError.rejected("excluded working entries require selection") }
        guard stagedTree == review.tree, latestWork == review.tree else { throw WorkspaceError.staleReview }
        exportBoundary?(.beforeRename)
        try checkpoint(action)
        try validate()
        try permittedDestination(parent)
        let parentNow = try Self.parent(destination).0
        guard try Self.identity(parent) == Self.identity(parentNow) else { throw WorkspaceError.mutated }
        try Self.verifyNamed(parent, stageName, stage)
        try checkpoint(action)
        // Immutable review digest + retained parent/new basename + captured owner
        // generation meet at the concrete commit. No callback inside this fence.
        try WorkspacePreparedEffect.publish(self, workflow, parent, stageName, name, review.sha256, stagedTree.digest).perform()
        writing.finish() // Never roll back after publication, including sync failure.
        exportBoundary?(.afterRename)
        do {
            try Self.verifyNamed(parent, name, stage)
            guard fsync(parent.value) == 0 else { throw WorkspaceError.io("export directory sync", errno) }
        } catch { throw WorkspaceError.committedUnverified(String(describing: error)) }
    }

    /// A separate explicit trusted-host export of an already captured review.
    /// Does not clear the workflow latch or reactivate any VM/run authority.
    /// The caller must obtain NEW host approval and a NEW action cancellation.
    public func exportReviewedAfterStop(_ review: WorkspaceReview, toNewDirectory destination: String,
                                       actionCancellation: WorkspaceExportCancellation) throws {
        effectLock.lock(); defer { effectLock.unlock() }
        if let quota = transferQuotas[review.snapshot], quota.handle.lifecycle.currentStatus != .active { cancellation.cancel() }
        guard cancellation.isCancelled, actionCancellation !== cancellation else { throw WorkspaceError.cancelled }
        try exportReviewed(review, toNewDirectory: destination, action: actionCancellation)
    }

    func acquireEffect() { effectLock.lock() }
    func releaseEffect() { effectLock.unlock() }
    func validateEffectLocked(_ workflow: WorkspaceWorkflowBinding) throws {
        guard let run = workflow.run else { return }
        guard run.storeOwner == owner, records[run.snapshot] != nil,
              transferBindings[run.snapshot] === run,
              run.snapshot.grantSnapshotID == transferQuotas[run.snapshot]?.snapshotID else { throw WorkspaceError.foreignSnapshot }
    }
    private func workspaceBinding(for id: WorkspaceSnapshotID) throws -> WorkspaceWorkflowBinding {
        let binding = try cancellation.binding()
        guard transferQuotas[id] != nil else { return binding }
        guard let run = transferBindings[id] else { throw WorkspaceError.foreignSnapshot }
        return try binding.bound(to: run)
    }
    private func makeEffectDirectory(_ parent: WorkspaceFD, _ name: String, workflow: WorkspaceWorkflowBinding) throws -> WorkspaceFD {
        try Self.trustedAncestors(parent)
        let result = try WorkspacePreparedEffect.create(self, workflow, parent, name, directory: true).perform()
        guard case .syscall(let raw, let failure) = result else { throw WorkspaceTransferError.rejected }
        guard raw == 0 else { throw WorkspaceError.io("exclusive mkdir", failure) }
        let fd = try Self.child(parent, name, directory: true)
        try Self.sanitize(fd, mode: 0o700)
        return fd
    }
    fileprivate func prepareAdoption(_ adoption: WorkspacePreparedAdoption) throws {
        guard let current = records[adoption.snapshot], current.work === adoption.previous.work else { throw WorkspaceError.staleReview }
        var nextRecords = records
        nextRecords[adoption.snapshot] = adoption.next
        adoption.previousRecords = records
        adoption.nextRecords = nextRecords
    }
    fileprivate func commitAdoption(_ adoption: WorkspacePreparedAdoption) throws {
        guard let current = records[adoption.snapshot], current.work === adoption.previous.work,
              let nextRecords = adoption.nextRecords else { throw WorkspaceError.staleReview }
        records = nextRecords
    }

    private func validateBindings() throws {
        try Self.verifyPath(rootPath, root)
        try Self.trustedAncestors(root)
        for (_, record) in records {
            try Self.verifyPath(record.sourcePath, record.source)
            try Self.verifyPath(record.workPath, record.work)
        }
    }
    private static func verifyPath(_ path: String, _ fd: WorkspaceFD) throws {
        do {
            let now = try openDirectory(path)
            guard try identity(now) == identity(fd) else { throw WorkspaceError.mutated }
        } catch { throw WorkspaceError.mutated }
    }
    private func permittedDestination(_ parent: WorkspaceFD) throws {
        try Self.trustedAncestors(parent)
        guard try !Self.isWithin(parent, root) else { throw WorkspaceError.rejected("managed destination") }
        for record in records.values {
            guard try !Self.isWithin(parent, record.source) else { throw WorkspaceError.rejected("source destination") }
        }
    }
    private func checkpoint(_ action: WorkspaceExportCancellation? = nil) throws {
        if let action {
            if action.isCancelled { throw WorkspaceError.cancelled }
            return
        }
        if cancelled() { cancellation.cancel() }
        if cancellation.isCancelled { throw WorkspaceError.cancelled }
    }
    private static func status(_ fd: WorkspaceFD) throws -> stat {
        var s = stat()
        guard fstat(fd.value, &s) == 0 else { throw WorkspaceError.io("fstat", errno) }
        return s
    }
    private static func identity(_ fd: WorkspaceFD) throws -> WorkspaceIdentity { WorkspaceIdentity(try status(fd)) }
    static func component(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              name.utf8.elementsEqual(name.precomposedStringWithCanonicalMapping.utf8) else { throw WorkspaceError.rejected("path component") }
    }
    private static func pathParts(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096 else { throw WorkspaceError.rejected("absolute bounded path required") }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts { try component(part) }
        return parts
    }
    private static func openDirectory(_ path: String) throws -> WorkspaceFD {
        let parts = try pathParts(path)
        var fd = try WorkspaceFD(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW))
        for part in parts { fd = try child(fd, part, directory: true) }
        return fd
    }
    private static func parent(_ path: String) throws -> (WorkspaceFD, String) {
        var parts = try pathParts(path)
        let name = parts.removeLast()
        let fd: WorkspaceFD
        if parts.isEmpty { fd = try WorkspaceFD(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)) }
        else { fd = try openDirectory("/" + parts.joined(separator: "/")) }
        return (fd, name)
    }
    // Pure stat classifier; device coverage needs no host device creation.
    static func checkNodeType(_ s: stat, directory: Bool = false) throws {
        let type = s.st_mode & S_IFMT
        guard type == S_IFDIR || (!directory && type == S_IFREG && s.st_nlink == 1) else {
            throw WorkspaceError.rejected("unsupported file type or hard link")
        }
    }
    private static func child(_ parent: WorkspaceFD, _ name: String, directory: Bool = false) throws -> WorkspaceFD {
        var before = stat()
        guard fstatat(parent.value, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw WorkspaceError.io("entry stat", errno) }
        try checkNodeType(before, directory: directory)
        let fd = try WorkspaceFD(openat(parent.value, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW | (directory ? O_DIRECTORY : 0)))
        let s = try status(fd)
        try checkNodeType(s, directory: directory)
        guard WorkspaceIdentity(before) == WorkspaceIdentity(s) else { throw WorkspaceError.mutated }
        try verifyNamed(parent, name, fd)
        return fd
    }
    private static func verifyNamed(_ parent: WorkspaceFD, _ name: String, _ fd: WorkspaceFD) throws {
        var s = stat()
        guard fstatat(parent.value, name, &s, AT_SYMLINK_NOFOLLOW) == 0,
              WorkspaceStamp(s) == WorkspaceStamp(try status(fd)) else { throw WorkspaceError.mutated }
    }
    private static func isWithin(_ child: WorkspaceFD, _ ancestor: WorkspaceFD) throws -> Bool {
        let target = try identity(ancestor)
        var current = child
        for _ in 0..<256 {
            let here = try identity(current)
            if here == target { return true }
            let up = try Self.child(current, "..", directory: true)
            if try identity(up) == here { return false }
            current = up
        }
        throw WorkspaceError.rejected("ancestry limit")
    }
    private static func disjoint(_ a: WorkspaceFD, _ b: WorkspaceFD) throws {
        if try isWithin(a, b) || isWithin(b, a) { throw WorkspaceError.rejected("overlapping roots") }
    }
    private static func checkACL(_ fd: WorkspaceFD, requireEmpty: Bool) throws {
        guard let acl = acl_get_fd_np(fd.value, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw WorkspaceError.io("read ACL", errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY
        while true {
            errno = 0
            let result = acl_get_entry(acl, Int32(which.rawValue), &entry)
            if result == -1 && errno == EINVAL { return } // Darwin end-of-list convention
            guard result == 0, let entry else { throw WorkspaceError.io("enumerate ACL", errno) }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { throw WorkspaceError.io("ACL tag", errno) }
            guard !requireEmpty, tag == ACL_EXTENDED_DENY else { throw WorkspaceError.rejected("unsafe ACL") }
            which = ACL_NEXT_ENTRY
        }
    }
    private static func sanitize(_ fd: WorkspaceFD, mode: mode_t) throws {
        guard let acl = acl_init(0) else { throw WorkspaceError.io("acl init", errno) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd(fd.value, acl) == 0, fchmod(fd.value, mode) == 0 else {
            throw WorkspaceError.io("sanitize permissions", errno)
        }
        // Only names are inspected on exclusively created nodes. Never read source
        // metadata values or remove OS markers. Unknown fresh-node metadata fails closed.
        let count = flistxattr(fd.value, nil, 0, 0)
        guard count >= 0, count <= 65_536 else { throw WorkspaceError.rejected("new-object xattr limit") }
        if count > 0 {
            var names = [CChar](repeating: 0, count: count)
            guard flistxattr(fd.value, &names, count, 0) == count else { throw WorkspaceError.mutated }
            var offset = 0
            while offset < count {
                let length = names[offset...].prefix(while: { $0 != 0 }).count
                guard length > 0, offset + length < count else { throw WorkspaceError.rejected("xattr names") }
                let name = names.withUnsafeBufferPointer { String(cString: $0.baseAddress!.advanced(by: offset)) }
                guard name == "com.apple.provenance" else { throw WorkspaceError.blockedPlatform("unexpected new-object xattr: " + name) }
                offset += length + 1
            }
        }
        let s = try status(fd)
        guard s.st_uid == geteuid(), s.st_mode & 0o7777 == mode else { throw WorkspaceError.rejected("new-object permissions") }
        try checkACL(fd, requireEmpty: true)
    }
    private static func trustedAncestors(_ start: WorkspaceFD) throws {
        var fd = start
        for _ in 0..<256 {
            let s = try status(fd)
            guard (s.st_uid == 0 || s.st_uid == geteuid()), s.st_mode & 0o022 == 0 else {
                throw WorkspaceError.rejected("unsafe ancestor permissions")
            }
            try checkACL(fd, requireEmpty: false)
            let up = try child(fd, "..", directory: true)
            if try identity(fd) == identity(up) { return }
            fd = up
        }
        throw WorkspaceError.rejected("ancestry limit")
    }
    private static func makeDirectory(_ parent: WorkspaceFD, _ name: String) throws -> WorkspaceFD {
        try trustedAncestors(parent)
        guard mkdirat(parent.value, name, 0o700) == 0 else { throw WorkspaceError.io("exclusive mkdir", errno) }
        let fd = try child(parent, name, directory: true)
        try sanitize(fd, mode: 0o700)
        return fd
    }
    static func excluded(_ name: String) -> Bool {
        let s = name.lowercased()
        return [".git", ".ssh", ".aws", ".azure", ".gnupg", ".config", ".npmrc", ".netrc", ".pypirc", "credentials", "id_rsa", "id_ed25519"].contains(s)
            || s == ".env" || s.hasPrefix(".env.") || s.hasSuffix(".pem") || s.hasSuffix(".key") || s.hasSuffix(".p12")
    }
    static func registerName(_ name: String, in names: inout Set<String>) throws {
        let key = name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard names.insert(key).inserted else { throw WorkspaceError.rejected("canonical collision") }
    }
    private func stableScan(_ root: WorkspaceFD, action: WorkspaceExportCancellation? = nil) throws -> WorkspaceTree {
        let first = try scan(root, action: action)
        let second = try scan(root, action: action)
        guard first.0 == second.0, first.1 == second.1 else { throw WorkspaceError.mutated }
        return first.0
    }
    private func scan(_ root: WorkspaceFD, action: WorkspaceExportCancellation?) throws -> (WorkspaceTree, [String: WorkspaceStamp]) {
        var result = WorkspaceTree()
        var stamps: [String: WorkspaceStamp] = [:]
        var count = 0
        var bytes = 0
        func visit(_ dir: WorkspaceFD, _ prefix: String, _ depth: Int) throws {
            try checkpoint(action)
            guard depth <= limits.depth else { throw WorkspaceError.rejected("depth limit") }
            let before = WorkspaceStamp(try Self.status(dir))
            stamps[prefix] = before
            let enumerationFD = openat(dir.value, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
            guard enumerationFD >= 0 else { throw WorkspaceError.io("enumerate open", errno) }
            guard let stream = fdopendir(enumerationFD) else { close(enumerationFD); throw WorkspaceError.io("fdopendir", errno) }
            defer { closedir(stream) }
            var names: [String] = []
            var canonical = Set<String>()
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw WorkspaceError.io("readdir", errno) }
                    break
                }
                let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
                }
                guard let name else { throw WorkspaceError.rejected("non UTF-8 name") }
                if name == "." || name == ".." { continue }
                count += 1
                guard count <= limits.entries else { throw WorkspaceError.rejected("entry limit") }
                try Self.component(name)
                try Self.registerName(name, in: &canonical)
                names.append(name)
            }
            for name in names.sorted() {
                try checkpoint(action)
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard path.utf8.count <= limits.pathBytes else { throw WorkspaceError.rejected("path limit") }
                if Self.excluded(name) { result.exclusions.append(path); continue }
                let fd = try Self.child(dir, name)
                let initial = try Self.status(fd)
                let stamp = WorkspaceStamp(initial)
                stamps[path] = stamp
                if initial.st_mode & S_IFMT == S_IFDIR {
                    result.nodes[path] = WorkspaceNode(data: nil)
                    try visit(fd, path, depth + 1)
                } else {
                    guard initial.st_size >= 0, initial.st_size <= limits.fileBytes,
                          initial.st_size <= limits.totalBytes - bytes else { throw WorkspaceError.rejected("byte limit") }
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    while true {
                        try checkpoint(action)
                        let n = read(fd.value, &buffer, buffer.count)
                        if n < 0 { if errno == EINTR { continue }; throw WorkspaceError.io("read", errno) }
                        if n == 0 { break }
                        guard n <= limits.fileBytes - data.count, n <= limits.totalBytes - bytes else { throw WorkspaceError.rejected("byte limit") }
                        data.append(contentsOf: buffer.prefix(n)); bytes += n
                        try didReadChunk?(path)
                    }
                    guard data.count == initial.st_size else { throw WorkspaceError.mutated }
                    result.nodes[path] = WorkspaceNode(data: data)
                }
                guard stamp == WorkspaceStamp(try Self.status(fd)) else { throw WorkspaceError.mutated }
                try Self.verifyNamed(dir, name, fd)
            }
            guard before == WorkspaceStamp(try Self.status(dir)) else { throw WorkspaceError.mutated }
        }
        try visit(root, "", 0)
        result.exclusions.sort()
        return (result, stamps)
    }
    private func materializationBytes(_ tree: WorkspaceTree, transferLimits: WorkspaceLimits? = nil) throws -> Int {
        let limits = transferLimits ?? self.limits
        guard tree.nodes.count <= limits.entries else { throw WorkspaceError.rejected("entry limit") }
        var total = 0
        for (path, node) in tree.nodes {
            guard path.utf8.count <= limits.pathBytes else { throw WorkspaceError.rejected("path limit") }
            // Match scan: root is depth zero; file basenames do not add depth,
            // but every directory component does, including an empty leaf.
            let depth = path.split(separator: "/").count - (node.data == nil ? 0 : 1)
            guard depth <= limits.depth else { throw WorkspaceError.rejected("depth limit") }
            if let data = node.data {
                guard data.count <= limits.fileBytes, data.count <= limits.totalBytes - total else { throw WorkspaceError.rejected("byte limit") }
                total += data.count
            }
        }
        return total
    }
    private func materialize(_ tree: WorkspaceTree, into root: WorkspaceFD, readOnly: Bool,
                             writing: WorkspaceDiskWrite? = nil, action: WorkspaceExportCancellation? = nil,
                             workflow requestedWorkflow: WorkspaceWorkflowBinding? = nil,
                             transferLimits: WorkspaceLimits? = nil,
                             validate: () throws -> Void) throws {
        let limits = transferLimits ?? self.limits
        _ = try materializationBytes(tree, transferLimits: limits)
        let workflow = try requestedWorkflow ?? (action ?? cancellation).binding()
        var written = 0
        var directories: [String: WorkspaceFD] = ["": root]
        for path in tree.nodes.keys.sorted() {
            try checkpoint(action)
            try validate()
            let parts = path.split(separator: "/").map(String.init)
            let parentPath = parts.dropLast().joined(separator: "/")
            guard let parent = directories[parentPath], let name = parts.last else { throw WorkspaceError.rejected("internal tree") }
            try Self.trustedAncestors(parent)
            if let data = tree.nodes[path]!.data {
                let created = try WorkspacePreparedEffect.create(self, workflow, parent, name, directory: false).perform()
                guard case .syscall(let raw, _) = created, raw >= 0 else {
                    if case .syscall(_, let failure) = created { throw WorkspaceError.io("open", failure) }
                    throw WorkspaceTransferError.rejected
                }
                let fd = try WorkspaceFD(Int32(raw))
                let index = writing?.track(parent, name, fd, directory: false)
                let s = try Self.status(fd)
                guard s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1 else { throw WorkspaceError.rejected("created file type") }
                try Self.sanitize(fd, mode: 0o600)
                try data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        try checkpoint(action)
                        try validate()
                        let amount = min(4096, raw.count - offset)
                        guard amount <= limits.fileBytes - offset, amount <= limits.totalBytes - written else { throw WorkspaceError.rejected("byte limit") }
                        if writing != nil { beforeTransferWrite?() }
                        let writtenResult = try WorkspacePreparedEffect.write(self, workflow, fd, raw.baseAddress!.advanced(by: offset), amount).perform()
                        guard case .syscall(let n, let failure) = writtenResult else { throw WorkspaceTransferError.rejected }
                        if n < 0 && failure == EINTR { continue }
                        guard n > 0 else { throw WorkspaceError.io("write", failure) }
                        offset += n; written += n
                        if let index { writing?.wrote(n, at: index) }
                        if writing != nil { didWriteTransferChunk?(n) }
                    }
                }
                guard fchmod(fd.value, readOnly ? 0o400 : 0o600) == 0, fsync(fd.value) == 0 else { throw WorkspaceError.io("file sync", errno) }
                try Self.verifyNamed(parent, name, fd)
            } else {
                let directory = try makeEffectDirectory(parent, name, workflow: workflow)
                writing?.track(parent, name, directory, directory: true)
                directories[path] = directory
            }
        }
        for fd in directories.values {
            try validate()
            guard fchmod(fd.value, readOnly ? 0o500 : 0o700) == 0, fsync(fd.value) == 0 else { throw WorkspaceError.io("directory sync", errno) }
        }
    }
    private func preview(_ node: WorkspaceNode?) -> WorkspacePreview? {
        guard let node else { return nil }
        guard let data = node.data else { return .noPreview("directory") }
        guard data.count <= limits.previewBytes else { return .noPreview("oversized") }
        guard let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { ($0.value < 32 && ![9,10,13].contains($0.value)) || $0.value == 127 }) else { return .noPreview("binary or non-text UTF-8") }
        return .text(text)
    }
    private func changes(_ before: WorkspaceTree, _ after: WorkspaceTree) -> [WorkspaceChange] {
        Set(before.nodes.keys).union(after.nodes.keys).sorted().compactMap { path in
            let a = before.nodes[path], b = after.nodes[path]
            guard a != b else { return nil }
            return WorkspaceChange(path: path, kind: a == nil ? .add : (b == nil ? .delete : .change),
                                   before: preview(a), after: preview(b))
        }
    }
}

/// Keeps both dictionary generations and descriptor owners alive until after
/// the lifecycle and workflow fences have been released.
final class WorkspacePreparedAdoption {
    let workflow: WorkspaceWorkflowBinding
    private let store: WorkspaceStore
    fileprivate let snapshot: WorkspaceSnapshotID
    fileprivate let previous: WorkspaceRecord
    fileprivate let next: WorkspaceRecord
    fileprivate var previousRecords: [WorkspaceSnapshotID: WorkspaceRecord]?
    fileprivate var nextRecords: [WorkspaceSnapshotID: WorkspaceRecord]?
    fileprivate init(store: WorkspaceStore, snapshot: WorkspaceSnapshotID, previous: WorkspaceRecord,
                     next: WorkspaceRecord, workflow: WorkspaceWorkflowBinding) {
        self.store = store; self.snapshot = snapshot; self.previous = previous; self.next = next; self.workflow = workflow
    }
    func acquire() { store.acquireEffect() }
    func prepare() throws { try store.prepareAdoption(self) }
    func validateOwner() throws { try store.validateEffectLocked(workflow) }
    func commitLocked() throws { try store.commitAdoption(self) }
    func release() { store.releaseEffect() }
}
