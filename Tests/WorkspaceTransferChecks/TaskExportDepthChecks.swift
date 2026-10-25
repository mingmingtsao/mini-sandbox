import Darwin
import Foundation
import SandboxContracts

@testable import SandboxHost

private struct DepthAudit: SynchronousAuditSink {
    func append(_ event: SecurityEvent) throws {}
}

// All filesystem inputs are synthetic data beneath the existing TMPDIR fixture.
@MainActor func taskExportDepthChecks(root: String, pass: (String) -> Void) async throws {
    let authority = RunAuthorizationController(auditSink: DepthAudit())
    var failures = [String]()
    for origin in ["imported", "modified-reviewed"] {
        for mode in ["ordinary", "postStop"] {
            for shape in ["file", "empty-directory"] {
                for (boundary, delta) in [("below", -1), ("exact", 0), ("above", 1)] {
                    let label = "R1 export depth \(origin) \(mode) \(shape) \(boundary)"
                    do {
                        try await taskExportDepthCase(
                            root: root, authority: authority,
                            origin: origin, mode: mode, shape: shape, boundary: boundary, delta: delta)
                        pass(label)
                    } catch {
                        // Continue to exercise every matrix row; do not swallow a failure.
                        failures.append(label)
                        print("FAIL " + label + ": " + String(describing: error))
                        fflush(stdout)
                    }
                }
            }
        }
    }
    try check(failures.isEmpty, "R1 export depth failed cases: " + failures.joined(separator: "; "))
}

@MainActor private func taskExportDepthCase(
    root: String, authority: RunAuthorizationController,
    origin: String, mode: String, shape: String, boundary: String, delta: Int
) async throws {
    let fm = FileManager.default
    let base = root + "/r1-depth-" + origin + "-" + mode + "-" + shape + "-" + boundary
    try check(mkdir(base, 0o700) == 0, "R1 owned case directory")
    let source = base + "/source"
    let destination = base + "/export"
    try check(mkdir(source, 0o700) == 0, "R1 owned source directory")
    let isFile = shape == "file"
    let postStop = mode == "postStop"
    // Files: limit 1, depths 0/1/2. Empty dirs: limit 2, depths 1/2/3.
    // A file basename never adds directory depth; an empty directory does.
    let effectiveDepth = isFile ? 1 : 2
    let treeDepth = effectiveDepth + delta
    let directories = (0..<treeDepth).map { "d" + String($0 + 1) }
    let leaf = (directories + (isFile ? ["a"] : [])).joined(separator: "/")
    let payload = Data([0x52, 0x31])
    let original = Data([0x49])
    func populate(_ path: String) throws {
        var current = path
        for directory in directories {
            current += "/" + directory
            try check(mkdir(current, 0o700) == 0, "R1 synthetic directory")
        }
        if isFile { try payload.write(to: URL(fileURLWithPath: current + "/a")) }
    }
    func paths(_ path: String) throws -> [String] {
        guard let e = fm.enumerator(atPath: path) else { throw NSError(domain: "R1 enumerate", code: 1) }
        return e.allObjects.compactMap { $0 as? String }.sorted()
    }
    var expectedPaths = [String]()
    for count in 1...max(1, treeDepth) where count <= treeDepth {
        expectedPaths.append(directories.prefix(count).joined(separator: "/"))
    }
    if isFile { expectedPaths.append(leaf) }
    if origin == "imported" {
        try populate(source)
    } else {
        try original.write(to: URL(fileURLWithPath: source + "/original.txt"))
    }
    let sourcePaths = try paths(source)
    var storeLimits = WorkspaceLimits()
    storeLimits.depth = 6
    let cancellation = WorkspaceExportCancellation()
    let store = try WorkspaceStore(newRoot: base + "/store", limits: storeLimits, cancellation: cancellation)
    let snapshot = try store.importTree(from: source)
    let quota = try await taskQuota(authority, snapshot.id)
    try store.bindTransferQuota(quota, for: snapshot.id)
    var caps = WorkspaceTaskLimits(retainedPayloadBytes: 32, diskBytes: 32, cumulativeInputBytes: 32)
    caps.depth = UInt64(effectiveDepth)
    caps.materializations = 1
    let task = try store.createTransferTask(for: snapshot.id, limits: caps)
    try check(quota.limits(store: storeLimits).depth == effectiveDepth, "R1 actual effective depth")
    try check(try store.createTransferTask(for: snapshot.id, limits: caps) === task, "R1 retained task identity")
    let bindingOwner = task.workflow.owner
    let bindingGeneration = task.workflow.generation
    if origin == "modified-reviewed" {
        try fm.removeItem(atPath: snapshot.workingDirectory + "/original.txt")
        try populate(snapshot.workingDirectory)
    }
    let review = try store.review(snapshot.id)
    try check(review.manifest.map(\.path).sorted() == expectedPaths.sorted(), "R1 exact reviewed tree")
    try check((origin == "imported") == review.changes.isEmpty, "R1 baseline versus modified review")
    let measuredDepth =
        review.manifest.map {
            $0.path.split(separator: "/").count - ($0.directory ? 0 : 1)
        }.max() ?? 0
    try check(measuredDepth == treeDepth, "R1 scanner directory-depth semantics")

    // Seed a nonzero cumulative input counter through the existing receiver seam.
    // Do not adopt it: the export must still use the imported/modified review.
    try quota.beginTransfer()
    let receiver = WorkspaceTransferReceiver(
        limits: quota.limits(store: storeLimits),
        budget: store.transferMemoryBudget, quota: quota, workflow: task.workflow)
    for message in try WorkspaceTransferWire.messages(["ledger": Data([0x4c])]) { try receiver.receive(message) }
    receiver.stop()
    receiver.stop()
    func metricValues(_ m: WorkspaceTransferBudget.Metrics) -> [Int] {
        [m.used, m.reserved, m.committed, m.peak, m.peakUsed, m.accepted, m.released, m.orphaned]
    }
    let memories = [store.transferMemoryBudget, quota.memory, task.memory]
    let memoryBefore = memories.map { metricValues($0.metrics) }
    try check(memoryBefore.allSatisfy { $0 == [0, 0, 0, 1, 1, 1, 1, 0] }, "R1 seeded settled input")
    let disks = [store.transferDiskBudget, quota.disk, task.disk]
    try check(disks.allSatisfy { metricValues($0.metrics) == Array(repeating: 0, count: 8) }, "R1 no prior disk charge")
    var beforeWrites = 0
    var writtenBytes = 0
    var beforeRenames = 0
    var afterRenames = 0
    store.beforeTransferWrite = { beforeWrites += 1 }
    store.didWriteTransferChunk = { writtenBytes += $0 }
    store.exportBoundary = {
        if $0 == .beforeRename { beforeRenames += 1 }
        if $0 == .afterRename { afterRenames += 1 }
    }
    let action = WorkspaceExportCancellation()
    func export(_ path: String) throws {
        if postStop {
            try store.exportReviewedAfterStop(review, toNewDirectory: path, actionCancellation: action)
        } else {
            try store.exportReviewed(review, toNewDirectory: path)
        }
    }
    func expectOldCancelled(_ suffix: String) throws {
        do {
            try store.exportReviewed(review, toNewDirectory: base + "/old-" + suffix)
            throw NSError(domain: "R1 old export revived", code: 1)
        } catch WorkspaceError.cancelled {}
        do {
            _ = try store.transferFlow(for: snapshot.id)
            throw NSError(domain: "R1 old transfer revived", code: 1)
        } catch WorkspaceError.cancelled {}
        do {
            try task.workflow.validate()
            throw NSError(domain: "R1 old binding revived", code: 1)
        } catch WorkspaceError.cancelled {}
        try check(!fm.fileExists(atPath: base + "/old-" + suffix), "R1 cancelled destination absent")
    }
    if postStop {
        task.cancel()
        task.cancel()
        try await authority.stop(handle: quota.handle)
        try expectOldCancelled("before")
    }
    var depthRejected = false
    do { try export(destination) } catch WorkspaceError.rejected("depth limit") { depthRejected = true }
    let stageResidue = try fm.contentsOfDirectory(atPath: base).filter { $0.hasPrefix(".workspace-stage-") }
    print(
        "MEASURE R1 \(origin) \(mode) \(shape) \(boundary) depthRejected=\(depthRejected) beforeWrite=\(beforeWrites) written=\(writtenBytes) beforeRename=\(beforeRenames) afterRename=\(afterRenames) survivingStages=\(stageResidue.count)"
    )
    fflush(stdout)
    try check(depthRejected == (delta > 0), "R1 exact depth rejection, not an unrelated error")
    try check(stageResidue.isEmpty, "R1 no surviving stage (not proof of no mkdir)")
    if delta > 0 {
        try check(!fm.fileExists(atPath: destination), "R1 above-depth destination absent")
        try check(
            beforeWrites == 0 && writtenBytes == 0 && beforeRenames == 0 && afterRenames == 0,
            "R1 no write/rename callback reached")
        try check(
            disks.allSatisfy { metricValues($0.metrics) == Array(repeating: 0, count: 8) },
            "R1 unchanged disk counters including reservation peaks")
        // The private attempt count has no getter. With cap=1, a successful claim
        // proves preflight did not consume it. This is a ledger observation, not
        // a mkdir syscall trace. Source order separately places claim before mkdir.
        try task.claimMaterialization()
        do {
            try task.claimMaterialization()
            throw NSError(domain: "R1 attempt cap absent", code: 1)
        } catch WorkspaceTransferError.rejected {}
    } else {
        try check(try paths(destination) == expectedPaths.sorted(), "R1 exact exported paths")
        if isFile {
            try check(
                try Data(contentsOf: URL(fileURLWithPath: destination + "/" + leaf)) == payload,
                "R1 exact exported bytes")
        } else {
            let attrs = try fm.attributesOfItem(atPath: destination + "/" + leaf)
            try check(attrs[.type] as? FileAttributeType == .typeDirectory, "R1 empty leaf retained as directory")
            try check(
                try fm.contentsOfDirectory(atPath: destination + "/" + leaf).isEmpty, "R1 empty leaf remains empty")
        }
        let bytes = isFile ? payload.count : 0
        try check(
            beforeWrites == (isFile ? 1 : 0) && writtenBytes == bytes && beforeRenames == 1 && afterRenames == 1,
            "R1 positive controls reach write and publication")
        try check(
            metricValues(task.disk.metrics) == [0, 0, bytes, bytes, bytes, bytes, 0, 0],
            "R1 retained committed task bytes")
        for disk in [store.transferDiskBudget, quota.disk] {
            try check(
                metricValues(disk.metrics) == [0, 0, 0, bytes, bytes, bytes, bytes, 0], "R1 store/run settlement")
        }
        let diskAfter = disks.map { metricValues($0.metrics) }
        do {
            try export(base + "/second")
            throw NSError(domain: "R1 export reset attempt budget", code: 1)
        } catch WorkspaceTransferError.rejected {}
        try check(
            !fm.fileExists(atPath: base + "/second") && disks.map { metricValues($0.metrics) } == diskAfter,
            "R1 repeated export cannot reset accounting, including zero-byte trees")
    }
    try check(memories.map { metricValues($0.metrics) } == memoryBefore, "R1 cumulative input never reset by export")
    try check(
        quota.task === task && task.workflow.owner == bindingOwner && task.workflow.generation == bindingGeneration,
        "R1 immutable task/workflow retained")
    if postStop {
        try check(
            cancellation.isCancelled && !action.isCancelled, "R1 independent action does not clear old cancellation")
        try expectOldCancelled("after")
    } else {
        try check(!cancellation.isCancelled, "R1 active workflow retained")
        try task.workflow.validate()
    }
    try check(try paths(source) == sourcePaths, "R1 source paths unchanged")
    if origin == "modified-reviewed" {
        try check(
            try Data(contentsOf: URL(fileURLWithPath: source + "/original.txt")) == original,
            "R1 original bytes unchanged")
    } else if isFile {
        try check(
            try Data(contentsOf: URL(fileURLWithPath: source + "/" + leaf)) == payload,
            "R1 imported source bytes unchanged")
    }
}
