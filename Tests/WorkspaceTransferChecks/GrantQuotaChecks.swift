import Foundation
import Darwin
import SandboxContracts
@testable import SandboxHost

private struct QuotaAudit: SynchronousAuditSink {
    func append(_ event: SecurityEvent) throws {}
}

@MainActor func grantQuotaChecks(root: String, pass: (String) -> Void) async throws {
    let authority = RunAuthorizationController(auditSink: QuotaAudit())
    let store = try WorkspaceStore(newRoot: root + "/grant-quota")
    let snapshot = try store.importTree(from: root + "/lower-fileBytes/source")
    let now = Date()
    let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(300), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "quota-fixture", workspaceSnapshotID: snapshot.id.grantSnapshotID, policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 2, diskBytes: 2, messageBytes: 16384, concurrentRequests: 2))
    let handle = try await authority.install(grant: grant)
    let quota = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: handle, grant: grant)
    try store.bindTransferQuota(quota, for: snapshot.id)
    let flow = try store.transferFlow(for: snapshot.id)
    var denied = false
    do {
        for message in try WorkspaceTransferWire.messages(["a": Data([1, 2, 3])]) { try flow.receiver.receive(message) }
    } catch WorkspaceTransferError.rejected { denied = true }
    if !denied || flow.receiver.acceptedBytes != 0 {
        print("FAIL installed grant 2 bytes bypassed: acceptedBytes=\(flow.receiver.acceptedBytes)"); fflush(stdout); exit(1)
    }
    _ = snapshot
    pass("R2 actual installed grant before allocation")
    let rawStore = try WorkspaceStore(newRoot: root + "/grant-message")
    let rawSnapshot = try rawStore.importTree(from: root + "/lower-fileBytes/source")
    let rawGrant = try quotaGrant(snapshot: rawSnapshot.id, message: 128)
    let rawHandle = try await authority.install(grant: rawGrant)
    let rawQuota = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: rawHandle, grant: rawGrant)
    try rawStore.bindTransferQuota(rawQuota, for: rawSnapshot.id)
    let probe = AgentRuntimeProbe(); probe.workspace = try rawStore.transferFlow(for: rawSnapshot.id)
    var rejectedHeader = false
    do { try probe.ingest(Data([0, 0, 0, 129])) } catch AgentRuntimeProbe.Failure.frame { rejectedHeader = true }
    if !rejectedHeader || !probe.stopping || !probe.input.isEmpty {
        print("FAIL installed message ceiling header admission: retained=\(probe.input.count)"); fflush(stdout); exit(1)
    }
    pass("R2 installed message ceiling rejects header before body")
    for amount in [127, 128, 129] {
        let p = AgentRuntimeProbe(); p.workspace = try rawStore.transferFlow(for: rawSnapshot.id)
        let ready = try frame(["v": 1, "type": "ready"])
        let body = ready + Data(repeating: 32, count: amount - ready.count)
        var denied = false
        do { for byte in framed(body) { try p.ingest(Data([byte])) } }
        catch AgentRuntimeProbe.Failure.frame { denied = true }
        try check(denied == (amount == 129) && p.frames == (amount == 129 ? 0 : 1), "raw grant message exact boundary")
        p.stop(true, "fixtureComplete")
    }
    pass("R2 installed raw message minus exact plus fragmented")

    let foreign = RunAuthorizationController(auditSink: QuotaAudit())
    do { _ = try await WorkspaceGrantQuota.authenticated(authority: foreign, handle: handle, grant: grant); throw NSError(domain: "foreign authority", code: 1) }
    catch AuthorizationError.invalidHandle {}
    let mismatch = try quotaGrant(snapshot: snapshot.id, memory: 1000)
    do { _ = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: handle, grant: mismatch); throw NSError(domain: "mismatched grant", code: 1) }
    catch AuthorizationError.grantBindingMismatch {}
    var decodedFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)) as! [String: Any]
    var decodedLimits = decodedFields["resourceLimits"] as! [String: Any]
    decodedLimits["memoryBytes"] = 1000; decodedFields["resourceLimits"] = decodedLimits
    let guestAltered = try JSONDecoder().decode(RunGrant.self, from: JSONSerialization.data(withJSONObject: decodedFields))
    do { _ = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: handle, grant: guestAltered); throw NSError(domain: "decoded limits elevated", code: 1) }
    catch AuthorizationError.grantBindingMismatch {}
    let differentHandle = try await authority.install(grant: mismatch)
    do { _ = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: differentHandle, grant: grant); throw NSError(domain: "wrong installed handle", code: 1) }
    catch AuthorizationError.grantBindingMismatch {}
    let bigger = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: differentHandle, grant: mismatch)
    do { try store.bindTransferQuota(bigger, for: snapshot.id); throw NSError(domain: "binding reset with bigger grant", code: 1) }
    catch WorkspaceTransferError.rejected {}
    let other = try store.importTree(from: root + "/lower-fileBytes/source")
    do { try store.bindTransferQuota(quota, for: other.id); throw NSError(domain: "workspace mismatch", code: 1) }
    catch WorkspaceError.foreignSnapshot {}
    do { try rawStore.bindTransferQuota(quota, for: snapshot.id); throw NSError(domain: "foreign store", code: 1) }
    catch WorkspaceError.foreignSnapshot {}
    do { _ = try store.transferFlow(files: [:]); throw NSError(domain: "unbound fallback", code: 1) }
    catch WorkspaceTransferError.rejected {}
    let unsigned = FrozenWorkspaceTransfer(files: ["a": Data([1])], sha256: WorkspaceTransferWire.treeHash(["a": Data([1])]))
    do { _ = try store.acceptTransfer(unsigned, for: snapshot.id); throw NSError(domain: "unbound frozen bypass", code: 1) }
    catch WorkspaceTransferError.rejected {}
    pass("R2 actual handle grant snapshot and no fallback binding")

    for dimension in ["memory", "disk"] {
        for amount in [1, 2, 3] {
            let base = root + "/installed-" + dimension + String(amount)
            let s = try WorkspaceStore(newRoot: base)
            let snap = try s.importTree(from: root + "/lower-fileBytes/source")
            let g = try quotaGrant(snapshot: snap.id, memory: dimension == "memory" ? 2 : UInt64.max, disk: dimension == "disk" ? 2 : UInt64.max)
            let h = try await authority.install(grant: g)
            let q = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: h, grant: g)
            try s.bindTransferQuota(q, for: snap.id)
            let f = try s.transferFlow(for: snap.id)
            try prime(f)
            let files = ["a": Data(repeating: 1, count: amount)]
            var rejected = false
            do { for b in try WorkspaceTransferWire.messages(files) { _ = try f.receive(b) } }
            catch WorkspaceTransferError.rejected { rejected = true }
            try check(rejected == (amount == 3) && f.receiver.acceptedBytes == (amount == 3 ? 0 : amount), "actual installed exact limits")
            if !rejected {
                let result = try f.receiver.snapshot()
                let path = try s.acceptTransfer(result, for: snap.id)
                try check(try Data(contentsOf: URL(fileURLWithPath: path + "/a")) == files["a"], "materialized exact bytes")
                let review = try s.review(snap.id)
                try s.exportReviewed(review, toNewDirectory: base + "-export")
                try check(try s.originalChanges(snap.id).isEmpty, "original retained")
                try check(q.disk.metrics.accepted == amount * 2 && q.disk.metrics.used == 0, "shared run disk actual materialization/export")
            } else {
                try check(try FileManager.default.contentsOfDirectory(atPath: base).filter { $0.hasPrefix("quarantine-") }.isEmpty, "oversized grant writes no quarantine")
            }
            f.receiver.stop()
            try check(q.memory.metrics.used == 0 && q.memory.metrics.reserved == 0 && q.disk.metrics.reserved == 0, "installed grant released capacity")
        }
        pass("R2 installed " + dimension + " minus exact plus materialize review export")
    }

    let again = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: handle, grant: grant)
    try check(again === quota, "repeated attachment cannot reset per-run pool")
    try store.bindTransferQuota(again, for: snapshot.id)
    try concurrentQuotaCheck(quota: quota, storeBudget: store.transferMemoryBudget,
                             flows: [try store.transferFlow(for: snapshot.id), try store.transferFlow(for: snapshot.id)])
    pass("R2 installed concurrent contexts exhaustion and cancellation recovery")
    var held: FrozenWorkspaceTransfer?
    do {
        let f = try store.transferFlow(for: snapshot.id); try prime(f)
        for b in try WorkspaceTransferWire.messages(["a": Data([1, 2])]) { _ = try f.receive(b) }
        held = try f.receiver.snapshot(); f.receiver.stop()
    }
    try check(quota.memory.metrics.used == 2, "frozen retention remains charged after channel destruction")
    let blocked = try store.transferFlow(for: snapshot.id); try prime(blocked)
    do { for b in try WorkspaceTransferWire.messages(["b": Data([1])]) { _ = try blocked.receive(b) }; throw NSError(domain: "frozen bypass", code: 1) }
    catch WorkspaceTransferError.rejected {}
    try check(blocked.receiver.acceptedBytes == 0 && held?.files["a"] == Data([1, 2]), "frozen immutable and overcommit refused")
    held = nil
    try check(quota.memory.metrics.used == 0 && quota.memory.metrics.reserved == 0, "last frozen reference releases")
    for reported in [1, 2] {
        let f = try store.transferFlow(for: snapshot.id); try prime(f)
        let wire = try WorkspaceTransferWire.messages(["a": Data([1, 2])])
        try f.receiver.receive(try frame(["v": 1, "type": "begin", "seq": 0, "count": 1, "total": reported]))
        try f.receiver.receive(try frame(["v": 1, "type": "file", "seq": 1, "path": "a", "size": reported, "sha256": WorkspaceTransferWire.hash(Data([1, 2]))]))
        var chunk = try JSONSerialization.jsonObject(with: wire[2]) as! [String: Any]
        chunk["data"] = Data([1, 2, 3]).base64EncodedString()
        do { try f.receiver.receive(try frame(chunk)); throw NSError(domain: "guest underreport", code: 1) }
        catch WorkspaceTransferError.rejected {}
        try check(f.receiver.acceptedBytes == 0 && quota.memory.metrics.used == 0, "actual chunk beyond grant/declaration preallocation")
    }
    let failed = try store.transferFlow(for: snapshot.id); try prime(failed)
    var corrupt = try WorkspaceTransferWire.messages(["a": Data([1, 2])])
    corrupt[2] = try frame(["v": 1, "type": "chunk", "seq": 2, "offset": 0, "data": Data([3, 4]).base64EncodedString()])
    do { for b in corrupt { _ = try failed.receive(b) }; throw NSError(domain: "digest failed", code: 1) }
    catch WorkspaceTransferError.rejected {}
    try check(failed.receiver.acceptedBytes == 2 && quota.memory.metrics.used == 0 && quota.memory.metrics.reserved == 0, "failure capacity recovery")
    pass("R2 installed frozen retention guest declarations actual chunks failure recovery")

    let constrained = try store.transferFlow(for: snapshot.id, channelLimits: tinyChannel())
    do { for b in try WorkspaceTransferWire.messages(["a": Data([1, 2])]) { try constrained.receiver.receive(b) }; throw NSError(domain: "channel increased by grant", code: 1) }
    catch WorkspaceTransferError.rejected {}
    try check(constrained.receiver.acceptedBytes == 0, "minimum includes lower channel")
    pass("R2 lower host channel remains effective under installed grant")
    let hugeFiles = ["a": Data([1, 2, 3])]
    // Trusted-host corruption injection: test materializer defense independently
    // of ingress. This constructor is not available to any guest wire format.
    let oversizedFrozen = FrozenWorkspaceTransfer(files: hugeFiles, sha256: WorkspaceTransferWire.treeHash(hugeFiles), quota: quota)
    do { _ = try store.acceptTransfer(oversizedFrozen, for: snapshot.id); throw NSError(domain: "materializer grant bypass", code: 1) }
    catch WorkspaceTransferError.rejected {}
    try check(store.transferDiskBudget.metrics.accepted == 0 && quota.disk.metrics.accepted == 0, "bound materializer prewrite ceiling")
    pass("R2 bound materializer independently rejects oversized frozen payload")

    let lowStore = try WorkspaceStore(newRoot: root + "/grant-low-store", limits: tinyChannel())
    let lowSnapshot = try lowStore.importTree(from: root + "/lower-fileBytes/source")
    let highGrant = try quotaGrant(snapshot: lowSnapshot.id, memory: UInt64.max, disk: UInt64.max)
    let highHandle = try await authority.install(grant: highGrant)
    let highQuota = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: highHandle, grant: highGrant)
    try lowStore.bindTransferQuota(highQuota, for: lowSnapshot.id)
    let lowFlow = try lowStore.transferFlow(for: lowSnapshot.id)
    do { for b in try WorkspaceTransferWire.messages(["a": Data([1, 2])]) { try lowFlow.receiver.receive(b) }; throw NSError(domain: "store increased by grant", code: 1) }
    catch WorkspaceTransferError.rejected {}
    try check(lowFlow.receiver.acceptedBytes == 0, "minimum includes actual store")
    pass("R2 UInt64 max grant cannot enlarge actual store")

    let diskCancellation = WorkspaceExportCancellation()
    let cancelStore = try WorkspaceStore(newRoot: root + "/grant-disk-cancel", cancellation: diskCancellation)
    let cancelSnap = try cancelStore.importTree(from: root + "/lower-fileBytes/source")
    let cancelGrant = try quotaGrant(snapshot: cancelSnap.id)
    let cancelHandle = try await authority.install(grant: cancelGrant)
    let cancelQuota = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: cancelHandle, grant: cancelGrant)
    try cancelStore.bindTransferQuota(cancelQuota, for: cancelSnap.id)
    let cancelFlow = try cancelStore.transferFlow(for: cancelSnap.id)
    for b in try WorkspaceTransferWire.messages(["a": Data(repeating: 1, count: 8192)]) { try cancelFlow.receiver.receive(b) }
    let cancelResult = try cancelFlow.receiver.snapshot()
    cancelStore.didWriteTransferChunk = { _ in diskCancellation.cancel() }
    do { _ = try cancelStore.acceptTransfer(cancelResult, for: cancelSnap.id); throw NSError(domain: "cancel installed materialization", code: 1) }
    catch WorkspaceError.cancelled {}
    try check(cancelQuota.disk.metrics.accepted == 4096 && cancelQuota.disk.metrics.used == 0 && cancelQuota.disk.metrics.reserved == 0 && cancelQuota.disk.metrics.released == 8192, "actual grant disk cancel settles only owned capacity")
    try check(try FileManager.default.contentsOfDirectory(atPath: root + "/grant-disk-cancel").filter { $0.hasPrefix("quarantine-") }.isEmpty, "cancel removes owned quarantine")
    do {
        let freshReservation = WorkspaceTransferReservation(cancelStore.transferDiskBudget, additional: cancelQuota.disk)
        try freshReservation.reserve(8192)
    }
    try check(cancelQuota.disk.metrics.used == 0 && cancelQuota.disk.metrics.reserved == 0 && diskCancellation.isCancelled, "capacity reusable without reviving workflow")
    print("MEASURE installedCancel written=\(cancelQuota.disk.metrics.accepted) actualPeak=\(cancelQuota.disk.metrics.peakUsed) reservationPeak=\(cancelQuota.disk.metrics.peak)")
    pass("R2 installed grant disk cancellation and capacity recovery")

    let orphanRoot = root + "/grant-orphan"
    let orphanStore = try WorkspaceStore(newRoot: orphanRoot)
    let orphanSnap = try orphanStore.importTree(from: root + "/lower-fileBytes/source")
    let orphanGrant = try quotaGrant(snapshot: orphanSnap.id, memory: 2, disk: 2)
    let orphanHandle = try await authority.install(grant: orphanGrant)
    let orphanQuota = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: orphanHandle, grant: orphanGrant)
    try orphanStore.bindTransferQuota(orphanQuota, for: orphanSnap.id)
    let orphanFlow = try orphanStore.transferFlow(for: orphanSnap.id)
    for b in try WorkspaceTransferWire.messages(["a": Data([1, 2])]) { try orphanFlow.receiver.receive(b) }
    let orphanResult = try orphanFlow.receiver.snapshot()
    var replaced = false, orphanPath = ""
    orphanStore.didWriteTransferChunk = { _ in
        guard !replaced, let children = try? FileManager.default.contentsOfDirectory(atPath: orphanRoot), let name = children.first(where: { $0.hasPrefix("quarantine-") }) else { return }
        orphanPath = orphanRoot + "/" + name
        guard rename(orphanPath + "/a", orphanPath + "/retained") == 0 else { return }
        let fd = open(orphanPath + "/a", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd >= 0 { close(fd); replaced = true }
    }
    do { _ = try orphanStore.acceptTransfer(orphanResult, for: orphanSnap.id); throw NSError(domain: "orphan replacement accepted", code: 1) }
    catch WorkspaceError.mutated {}
    try check(replaced && FileManager.default.fileExists(atPath: orphanPath + "/a") && FileManager.default.fileExists(atPath: orphanPath + "/retained"), "rollback preserves unknown replacement and moved owned bytes")
    try check(orphanQuota.disk.metrics.used == 2 && orphanQuota.disk.metrics.orphaned == 2 && orphanQuota.disk.metrics.reserved == 0, "run orphan charge remains")
    let reattached = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: orphanHandle, grant: orphanGrant)
    try check(reattached === orphanQuota && reattached.disk.metrics.orphaned == 2, "reattach cannot reset orphans")
    orphanStore.didWriteTransferChunk = nil
    do { _ = try orphanStore.acceptTransfer(orphanResult, for: orphanSnap.id); throw NSError(domain: "orphan capacity bypass", code: 1) }
    catch WorkspaceTransferError.rejected {}
    try check(orphanStore.transferDiskBudget.metrics.used == 2 && orphanStore.transferDiskBudget.metrics.reserved == 0, "both levels retain orphan capacity")
    try check(try FileManager.default.contentsOfDirectory(atPath: orphanRoot).filter { $0.hasPrefix("quarantine-") }.count == 1, "failed second reservation creates no quarantine")
    print("MEASURE installedOrphan written=\(orphanQuota.disk.metrics.accepted) used=\(orphanQuota.disk.metrics.used) orphaned=\(orphanQuota.disk.metrics.orphaned)")
    pass("R2 installed orphan charges survive rollback and reattachment")
    try await authority.stop(handle: handle)
    do { _ = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: handle, grant: grant); throw NSError(domain: "stopped reattach", code: 1) }
    catch AuthorizationError.runRevoked {}
    pass("R2 stopped F03 handle cannot newly authenticate quota")
    var registryDenied = false
    for _ in 0..<257 {
        let g = try quotaGrant(snapshot: orphanSnap.id)
        let h = try await authority.install(grant: g)
        do { _ = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: h, grant: g) }
        catch WorkspaceTransferError.rejected { registryDenied = true; break }
    }
    try check(registryDenied, "bounded quota registry fails closed")
    let retainedOrphan = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: orphanHandle, grant: orphanGrant)
    try check(retainedOrphan === orphanQuota && retainedOrphan.disk.metrics.orphaned == 2, "registry exhaustion never evicts orphan charge")
    pass("R2 quota registry exhaustion preserves existing orphan domain")
}

private func tinyChannel() -> WorkspaceLimits { var limits = WorkspaceLimits(); limits.totalBytes = 1; return limits }

private func prime(_ flow: WorkspaceTransferFlow) throws {
    var body = try flow.receive(frame(["v": 1, "type": "ready"]))
    var seq = 0
    while body != nil {
        body = try flow.receive(frame(["v": 1, "type": "ack", "seq": seq])); seq += 1
        try check(seq <= 8192, "bounded fixture handshake")
    }
}

private final class OwnedQuotaFlow: @unchecked Sendable {
    // Transferred once to one worker; no other accesses until the worker settles.
    let flow: WorkspaceTransferFlow
    init(_ flow: WorkspaceTransferFlow) { self.flow = flow }
}
private final class QuotaOutcomes: @unchecked Sendable {
    let lock = NSLock()
    var accepted = 0, rejected = 0, unexpected = 0, timedOut = false
}
private func concurrentQuotaCheck(quota: WorkspaceGrantQuota, storeBudget: WorkspaceTransferBudget, flows: [WorkspaceTransferFlow]) throws {
    let attempts = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), workers = DispatchGroup()
    let outcomes = QuotaOutcomes()
    for flow in flows {
        let owner = OwnedQuotaFlow(flow)
        workers.enter()
        DispatchQueue.global().async {
            do {
                try prime(owner.flow)
                for frame in try WorkspaceTransferWire.messages(["a": Data([1, 2])]) { _ = try owner.flow.receive(frame) }
                outcomes.lock.withLock { outcomes.accepted += 1 }
            } catch WorkspaceTransferError.rejected { outcomes.lock.withLock { outcomes.rejected += 1 } }
            catch { outcomes.lock.withLock { outcomes.unexpected += 1 } }
            attempts.signal()
            if release.wait(timeout: .now() + 5) != .success { outcomes.lock.withLock { outcomes.timedOut = true } }
            owner.flow.receiver.stop(); workers.leave()
        }
    }
    let one = attempts.wait(timeout: .now() + 5), two = attempts.wait(timeout: .now() + 5)
    let observed = quota.memory.metrics
    release.signal(); release.signal()
    let settled = workers.wait(timeout: .now() + 5)
    try check(one == .success && two == .success && settled == .success, "quota barriers settled")
    try check(outcomes.lock.withLock { outcomes.accepted == 1 && outcomes.rejected == 1 && outcomes.unexpected == 0 && !outcomes.timedOut }, "one actual flow accepted and one quota rejection")
    try check(observed.used == 2 && observed.accepted == 2 && observed.reserved == 0, "only one concurrent installed allocation")
    try check(quota.memory.metrics.used == 0 && storeBudget.metrics.used == 0 && storeBudget.metrics.reserved == 0, "dual reservation rollback and cancellation")
}

private func quotaGrant(snapshot: WorkspaceSnapshotID, memory: UInt64 = 8192, disk: UInt64 = 8192, message: Int = 16384) throws -> RunGrant {
    let now = Date()
    return try RunGrant(runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(300), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "quota-fixture", workspaceSnapshotID: snapshot.grantSnapshotID, policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: memory, diskBytes: disk, messageBytes: message, concurrentRequests: 2))
}
