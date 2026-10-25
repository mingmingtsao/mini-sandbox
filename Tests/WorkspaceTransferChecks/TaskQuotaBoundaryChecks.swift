import Darwin
import Foundation
import SandboxContracts

@testable import SandboxHost

private final class TaskQuotaFlow: @unchecked Sendable {
    let flow: WorkspaceTransferFlow
    init(_ flow: WorkspaceTransferFlow) { self.flow = flow }
}
private final class TaskQuotaOutcomes: @unchecked Sendable {
    let lock = NSLock()
    var accepted = 0, rejected = 0, unexpected = 0, timedOut = false
}

@MainActor func taskBoundaryChecks(root: String, authority: RunAuthorizationController, pass: (String) -> Void)
    async throws
{
    func make(
        _ name: String, _ limits: WorkspaceTaskLimits,
        cancellation: WorkspaceExportCancellation = WorkspaceExportCancellation()
    ) async throws -> (WorkspaceStore, WorkspaceSnapshot, WorkspaceGrantQuota, TaskQuotaLedger) {
        let s = try WorkspaceStore(newRoot: root + "/r3-boundary-" + name, cancellation: cancellation)
        let snap = try s.importTree(from: root + "/lower-fileBytes/source")
        let q = try await taskQuota(authority, snap.id)
        try s.bindTransferQuota(q, for: snap.id)
        let task = try s.createTransferTask(for: snap.id, limits: limits)
        return (s, snap, q, task)
    }
    func feed(_ flow: WorkspaceTransferFlow, _ amount: Int) throws {
        for bytes in try WorkspaceTransferWire.messages(["a": Data(repeating: 42, count: amount)]) {
            try flow.receiver.receive(bytes)
        }
    }
    for dimension in ["memory", "disk", "cumulative"] {
        for amount in [1, 2, 3] {
            let caps = WorkspaceTaskLimits(
                retainedPayloadBytes: dimension == "memory" ? 2 : 8, diskBytes: dimension == "disk" ? 2 : 8,
                cumulativeInputBytes: dimension == "cumulative" ? 2 : 8)
            let (s, snap, _, task) = try await make(dimension + String(amount), caps)
            let f = try s.transferFlow(for: snap.id)
            var denied = false
            do { try feed(f, amount) } catch WorkspaceTransferError.rejected { denied = true }
            try check(
                denied == (amount == 3) && f.receiver.acceptedBytes == (amount == 3 ? 0 : amount),
                "task exact boundary " + dimension)
            f.receiver.stop()
            f.receiver.stop()
            try check(task.memory.metrics.used == 0 && task.memory.metrics.reserved == 0, "exact-once repeated close")
        }
        pass("R3 task " + dimension + " minus exact plus preallocation")
    }
    let generous = WorkspaceTaskLimits(
        retainedPayloadBytes: UInt64.max, diskBytes: UInt64.max, cumulativeInputBytes: UInt64.max)
    let (s, snap, q, task) = try await make("identity", generous)
    let same = try s.createTransferTask(for: snap.id, limits: generous)
    try check(same === task, "same host task identity")
    do {
        _ = try s.createTransferTask(
            for: snap.id, limits: WorkspaceTaskLimits(retainedPayloadBytes: 1, diskBytes: 1, cumulativeInputBytes: 1))
        throw NSError(domain: "task reset", code: 1)
    } catch WorkspaceTransferError.rejected {}
    var channel = WorkspaceLimits()
    channel.totalBytes = 1
    let small = try s.transferFlow(for: snap.id, channelLimits: channel)
    do {
        try feed(small, 2)
        throw NSError(domain: "channel reset", code: 1)
    } catch WorkspaceTransferError.rejected {}
    let overflow = WorkspaceTransferReservation(task.memory)
    do {
        try overflow.reserve(Int.max)
        throw NSError(domain: "integer overflow", code: 1)
    } catch WorkspaceTransferError.rejected {}
    try check(
        task.memory.metrics.used == 0 && task.memory.metrics.reserved == 0 && q.memory.metrics.used == 0,
        "oversized rejected without growth")
    let lateStore = try WorkspaceStore(newRoot: root + "/r3-late-task")
    let lateSnap = try lateStore.importTree(from: root + "/lower-fileBytes/source")
    let lateQuota = try await taskQuota(authority, lateSnap.id)
    try lateStore.bindTransferQuota(lateQuota, for: lateSnap.id)
    _ = try lateStore.transferFlow(for: lateSnap.id)
    do {
        _ = try lateStore.createTransferTask(for: lateSnap.id, limits: generous)
        throw NSError(domain: "late limits reset", code: 1)
    } catch WorkspaceTransferError.rejected {}
    pass("R3 task identity no reset late binding UInt64 overflow channel intersection")

    var messages = generous
    messages.messageBytes = 128
    let (ms, mn, _, mt) = try await make("message", messages)
    let probe = AgentRuntimeProbe()
    probe.workspace = try ms.transferFlow(for: mn.id)
    do {
        try probe.ingest(Data([0, 0, 0, 129]))
        throw NSError(domain: "task raw header", code: 1)
    } catch AgentRuntimeProbe.Failure.frame {}
    try check(
        probe.stopping && probe.input.isEmpty && mt.memory.metrics.accepted == 0, "task message bound at raw read")
    pass("R3 task message ceiling at native raw header")

    let (fs, fn, _, ft) = try await make(
        "frozen", WorkspaceTaskLimits(retainedPayloadBytes: 2, diskBytes: 8, cumulativeInputBytes: 4))
    var held: FrozenWorkspaceTransfer?
    do {
        let f = try fs.transferFlow(for: fn.id)
        try feed(f, 2)
        held = try f.receiver.snapshot()
        f.receiver.stop()
        f.receiver.stop()
    }
    try check(
        ft.memory.metrics.used == 2 && ft.memory.metrics.accepted == 2, "retained task frozen bytes survive close")
    let blocked = try fs.transferFlow(for: fn.id)
    do {
        try feed(blocked, 1)
        throw NSError(domain: "frozen task bypass", code: 1)
    } catch WorkspaceTransferError.rejected {}
    try check(
        held?.files["a"]?.count == 2 && ft.memory.metrics.accepted == 2,
        "failed additional budget rolls back cumulative reservation")
    held = nil
    let fresh = try fs.transferFlow(for: fn.id)
    try feed(fresh, 2)
    fresh.receiver.stop()
    try check(
        ft.memory.metrics.accepted == 4 && ft.memory.metrics.used == 0 && ft.memory.metrics.reserved == 0,
        "capacity reuse preserves lifetime input")
    pass("R3 frozen payload retention close and cumulative capacity reuse")

    let (badStore, badSnap, _, badTask) = try await make(
        "bad", WorkspaceTaskLimits(retainedPayloadBytes: 2, diskBytes: 8, cumulativeInputBytes: 2))
    let bad = try badStore.transferFlow(for: badSnap.id)
    var wire = try WorkspaceTransferWire.messages(["a": Data([1, 2])])
    wire[2] = try frame(["v": 1, "seq": 2, "type": "chunk", "offset": 0, "data": "!!!!"])
    do {
        for b in wire { try bad.receiver.receive(b) }
        throw NSError(domain: "bad base64", code: 1)
    } catch WorkspaceTransferError.rejected {}
    try check(
        badTask.memory.metrics.used == 0 && badTask.memory.metrics.reserved == 0
            && badTask.memory.metrics.accepted == 0, "decode failure refunds only unaccepted reservation")
    let corrupt = try badStore.transferFlow(for: badSnap.id)
    wire = try WorkspaceTransferWire.messages(["a": Data([1, 2])])
    wire[2] = try frame(["v": 1, "seq": 2, "type": "chunk", "offset": 0, "data": Data([3, 4]).base64EncodedString()])
    do {
        for b in wire { try corrupt.receiver.receive(b) }
        throw NSError(domain: "bad digest", code: 1)
    } catch WorkspaceTransferError.rejected {}
    try check(
        badTask.memory.metrics.used == 0 && badTask.memory.metrics.reserved == 0
            && badTask.memory.metrics.accepted == 2, "digest failure never refunds actual input")
    pass("R3 malformed decode and digest failure settle different counters")

    // This executable is the queue-owned child. Never alter the coordinator's limits.
    let (ss, sn, _, st) = try await make(
        "shortwrite", WorkspaceTaskLimits(retainedPayloadBytes: 8192, diskBytes: 16384, cumulativeInputBytes: 8192))
    let sf = try ss.transferFlow(for: sn.id)
    try feed(sf, 8192)
    let frozen = try sf.receiver.snapshot()
    var old = rlimit()
    try check(getrlimit(RLIMIT_FSIZE, &old) == 0, "read child limit")
    let oldSignal = signal(SIGXFSZ, SIG_IGN)
    var limited = old
    limited.rlim_cur = 4097
    try check(setrlimit(RLIMIT_FSIZE, &limited) == 0, "set child limit")
    var exact = false
    do { _ = try ss.acceptTransfer(frozen, for: sn.id) } catch WorkspaceError.io("write", EFBIG) { exact = true } catch
    {
        _ = setrlimit(RLIMIT_FSIZE, &old)
        signal(SIGXFSZ, oldSignal)
        throw error
    }
    try check(setrlimit(RLIMIT_FSIZE, &old) == 0, "restore child limit")
    signal(SIGXFSZ, oldSignal)
    let m = st.disk.metrics
    try check(
        exact && m.accepted == 4097 && m.peakUsed == 4097 && m.peak == 8192 && m.used == 0 && m.reserved == 0
            && m.committed == 0 && m.orphaned == 0 && m.released == 8192, "task exact real short-write settlement")
    try check(
        try FileManager.default.contentsOfDirectory(atPath: root + "/r3-boundary-shortwrite").filter {
            $0.hasPrefix("quarantine-")
        }.isEmpty, "short write cleans owned quarantine")
    _ = try ss.acceptTransfer(frozen, for: sn.id)
    try ss.exportReviewed(ss.review(sn.id), toNewDirectory: root + "/r3-short-export")
    try check(
        st.disk.metrics.accepted == 20481 && st.disk.metrics.committed == 16384 && st.disk.metrics.used == 0
            && st.disk.metrics.reserved == 0 && st.disk.metrics.peakUsed == 16384,
        "shortwrite capacity reuse commits retained trees")
    print(
        "MEASURE R3 shortWrite=\(m.accepted) actualPeak=\(m.peakUsed) reservedPeak=\(m.peak) released=\(m.released) cumulativeWritten=\(st.disk.metrics.accepted) committed=\(st.disk.metrics.committed)"
    )
    pass("R3 actual short write EFBIG exact settlement and capacity reuse")

    let (cs, cn, cq, ct) = try await make(
        "concurrent", WorkspaceTaskLimits(retainedPayloadBytes: 2, diskBytes: 8, cumulativeInputBytes: 4))
    func concurrentCheck() throws {
        let attempts = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let outcomes = TaskQuotaOutcomes()
        for _ in 0..<2 {
            let holder = TaskQuotaFlow(try cs.transferFlow(for: cn.id))
            group.enter()
            DispatchQueue.global().async {
                do {
                    for b in try WorkspaceTransferWire.messages(["a": Data([1]), "b": Data([2])]) {
                        try holder.flow.receiver.receive(b)
                    }
                    outcomes.lock.withLock { outcomes.accepted += 1 }
                } catch WorkspaceTransferError.rejected { outcomes.lock.withLock { outcomes.rejected += 1 } } catch {
                    outcomes.lock.withLock { outcomes.unexpected += 1 }
                }
                attempts.signal()
                if release.wait(timeout: .now() + 5) != .success { outcomes.lock.withLock { outcomes.timedOut = true } }
                holder.flow.receiver.stop()
                holder.flow.receiver.stop()
                group.leave()
            }
        }
        let arrived1 = attempts.wait(timeout: .now() + 5)
        let arrived2 = attempts.wait(timeout: .now() + 5)
        let concurrent = ct.memory.metrics
        release.signal()
        release.signal()
        let settled = group.wait(timeout: .now() + 5)
        try check(
            arrived1 == .success && arrived2 == .success && settled == .success, "concurrent task barrier settled")
        // A chunk-level race may split capacity across both streams. Neither may
        // exceed the shared domain, and all actual input remains charged forever.
        try check(
            outcomes.lock.withLock {
                outcomes.unexpected == 0 && !outcomes.timedOut && outcomes.accepted + outcomes.rejected == 2
            }, "all worker outcomes known")
        try check(
            concurrent.peakUsed <= 2 && ct.memory.metrics.used == 0 && ct.memory.metrics.reserved == 0
                && cq.memory.metrics.used == 0, "task aggregate safe through simultaneous channels")
        try check(
            ct.memory.metrics.accepted <= 4 && ct.memory.metrics.accepted >= 2, "actual aggregate input survives close")
    }
    try concurrentCheck()
    pass("R3 simultaneous channels share task reservations and exact close")

    let (os, on, oq, ot) = try await make(
        "orphan", WorkspaceTaskLimits(retainedPayloadBytes: 2, diskBytes: 2, cumulativeInputBytes: 4))
    let of = try os.transferFlow(for: on.id)
    try feed(of, 2)
    let owned = try of.receiver.snapshot()
    let orphanRoot = root + "/r3-boundary-orphan"
    var replaced = false
    os.didWriteTransferChunk = { _ in
        guard !replaced, let entries = try? FileManager.default.contentsOfDirectory(atPath: orphanRoot),
            let name = entries.first(where: { $0.hasPrefix("quarantine-") })
        else { return }
        let path = orphanRoot + "/" + name
        guard rename(path + "/a", path + "/retained") == 0 else { return }
        let fd = open(path + "/a", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd >= 0 {
            close(fd)
            replaced = true
        }
    }
    do {
        _ = try os.acceptTransfer(owned, for: on.id)
        throw NSError(domain: "task orphan", code: 1)
    } catch WorkspaceError.mutated {}
    try check(
        replaced && ot.disk.metrics.used == 2 && ot.disk.metrics.orphaned == 2 && ot.disk.metrics.reserved == 0
            && ot.disk.metrics.committed == 0, "unknown orphan capacity never released")
    try check(
        try os.createTransferTask(for: on.id, limits: ot.hostLimits) === ot && oq.task === ot,
        "same installed task retains orphan")
    os.didWriteTransferChunk = nil
    do {
        _ = try os.acceptTransfer(owned, for: on.id)
        throw NSError(domain: "orphan capacity reset", code: 1)
    } catch WorkspaceTransferError.rejected {}
    ot.cancel()
    ot.cancel()
    try check(
        oq.task?.disk.metrics.orphaned == 2 && ot.disk.metrics.used == 2, "cancel no task eviction or free headroom")
    pass("R3 orphan charges survive task reattachment and cancellation")

    // Zero-byte streams and empty exports must still have a bounded task lifetime.
    let (zs, zn, _, _) = try await make(
        "zero", WorkspaceTaskLimits(retainedPayloadBytes: 2, diskBytes: 8, cumulativeInputBytes: 4))
    let zeroReview = try zs.review(zn.id)
    var transferDenials = 0
    var exportDenials = 0
    for index in 0..<65 {
        do { _ = try zs.transferFlow(for: zn.id) } catch WorkspaceTransferError.rejected { transferDenials += 1 }
        do {
            try zs.exportReviewed(zeroReview, toNewDirectory: root + "/r3-zero-export-" + String(index))
        } catch WorkspaceTransferError.rejected { exportDenials += 1 }
    }
    print("MEASURE R3 zeroBytes transferDenials=\(transferDenials) exportDenials=\(exportDenials)")
    fflush(stdout)
    try check(
        transferDenials == 1 && exportDenials == 1
            && !FileManager.default.fileExists(atPath: root + "/r3-zero-export-64"),
        "R3 zero-byte task cannot bypass bounded attempts and materializations")
    pass("R3 zero-byte transfer and export lifetime remain bounded")

    for stage in ["before", "after", "unverified"] {
        let cancellation = WorkspaceExportCancellation()
        let (es, en, eq, et) = try await make(
            "commit-" + stage, WorkspaceTaskLimits(retainedPayloadBytes: 2, diskBytes: 8, cumulativeInputBytes: 4),
            cancellation: cancellation)
        let ef = try es.transferFlow(for: en.id)
        try feed(ef, 2)
        _ = try es.acceptTransfer(ef.receiver.snapshot(), for: en.id)
        let review = try es.review(en.id)
        let destination = root + "/r3-commit-" + stage
        var moved = false
        es.exportBoundary = { boundary in
            if stage == "before" && boundary == .beforeRename { et.cancel() }
            if stage == "after" && boundary == .afterRename { et.cancel() }
            if stage == "unverified" && boundary == .afterRename {
                moved = rename(destination, destination + "-moved") == 0
            }
        }
        if stage == "before" {
            do {
                try es.exportReviewed(review, toNewDirectory: destination)
                throw NSError(domain: "cancel before commit", code: 1)
            } catch WorkspaceError.cancelled {}
            try check(
                !FileManager.default.fileExists(atPath: destination) && et.disk.metrics.committed == 2
                    && et.disk.metrics.released == 2, "cancel-before never publishes")
        } else if stage == "after" {
            try es.exportReviewed(review, toNewDirectory: destination)
            try check(
                FileManager.default.fileExists(atPath: destination + "/a") && et.disk.metrics.committed == 4,
                "rename-before cancellation truthfully committed")
        } else {
            do {
                try es.exportReviewed(review, toNewDirectory: destination)
                throw NSError(domain: "unknown commit", code: 1)
            } catch WorkspaceError.committedUnverified {}
            try check(
                moved && et.disk.metrics.committed == 4 && et.disk.metrics.used == 0, "postcommit fault remains charged"
            )
            et.cancel()
        }
        es.exportBoundary = nil
        try await authority.stop(handle: eq.handle)
        try es.exportReviewedAfterStop(
            review, toNewDirectory: destination + "-approved", actionCancellation: WorkspaceExportCancellation())
        try check(
            cancellation.isCancelled && et.memory.metrics.accepted == 2,
            "explicit action neither resets input nor revives run")
        do {
            _ = try es.transferFlow(for: en.id)
            throw NSError(domain: "revived task", code: 1)
        } catch WorkspaceError.cancelled {}
        do {
            try es.exportReviewed(review, toNewDirectory: destination + "-old")
            throw NSError(domain: "revived old export", code: 1)
        } catch WorkspaceError.cancelled {}
        try check(et.disk.metrics.reserved == 0 && et.disk.metrics.used == 0, "commit settlement exact once")
        pass("R3 task rename ordering " + stage + " and independent postStop export")
    }
}
