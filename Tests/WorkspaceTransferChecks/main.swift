import Foundation
import CryptoKit
import Darwin
@testable import SandboxHost
import SandboxContracts

func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw NSError(domain: label, code: 1) }
}
func frame(_ d: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) }
func framed(_ body:Data) -> Data {var size=UInt32(body.count).bigEndian;var result=Data();withUnsafeBytes(of:&size){result.append(contentsOf:$0)};result.append(body);return result}
@main struct Checks {
 static func main() async throws {
    let (root, oldLabels) = try legacyChecks()
    var labels = oldLabels
    try await taskQuotaChecks(root: root) { label in labels.append(label); print("PASS " + label); fflush(stdout) }
    try await taskExportDepthChecks(root: root) { label in labels.append(label); print("PASS " + label); fflush(stdout) }
    try await grantQuotaChecks(root: root) { label in labels.append(label); print("PASS " + label); fflush(stdout) }
    print("RESULT cases=\(labels.count) unique=\(Set(labels).count) failures=0")
 }
 static func legacyChecks() throws -> (String, [String]) {
    var labels=[String]()
    func pass(_ label:String) {labels.append(label);print("PASS "+label);fflush(stdout)}
    let data = Data("def add(a,b): return a+b\n".utf8)
    let receiver = WorkspaceTransferReceiver()
    let messages = try WorkspaceTransferWire.messages(["logic.py":data])
    for message in messages { try receiver.receive(message) }
    let frozen = try receiver.snapshot()
    try check(frozen.files["logic.py"] == data, "complete exact snapshot")
    do { try receiver.receive(messages[1]); throw NSError(domain:"late frame accepted",code:1) }
    catch WorkspaceTransferError.rejected {}
    try check(frozen.files["logic.py"] == data, "sealed value unaffected by late frame")
    pass("complete/freeze/late-frame")
    let probe=AgentRuntimeProbe()
    do { try probe.ingest(Data([0,1,0,0])) } catch {}
    try check(probe.stopping, "oversized native ingress must poison session immediately")
    pass("native oversized ingress poison")
    func prepared() throws -> AgentRuntimeProbe {
        let p=AgentRuntimeProbe();p.workspace=try WorkspaceTransferFlow(files:[:])
        let ready=try frame(["v":1,"type":"ready"])
        for byte in framed(ready) {try p.ingest(Data([byte]))}
        p.output.removeAll()
        for i in 0..<2 {try p.receive(try frame(["v":1,"type":"ack","seq":i]));p.output.removeAll()}
        return p
    }
    func rejected(_ label:String,_ bodies:[Data]) throws {
        let p=try prepared();var rejected=false
        do {for body in bodies {try p.ingest(framed(body))}} catch {rejected=true}
        try check(rejected && p.stopping && p.workspaceResult==nil && p.output.isEmpty && p.workspace!.receiver.poisoned,label)
        do {_ = try p.workspace!.receiver.snapshot();throw NSError(domain:"partial snapshot",code:1)} catch WorkspaceTransferError.rejected {}
        do {try p.ingest(framed(messages[0]));throw NSError(domain:"revived session",code:1)} catch AgentRuntimeProbe.Failure.order {}
        pass(label)
    }
    let begin=String(data:messages[0],encoding:.utf8)!
    for token in ["true","1.0","1e0","-0"] {
        try rejected("numeric "+token,[Data(begin.replacingOccurrences(of:"\"count\":1",with:"\"count\":"+token).utf8)])
    }
    for extra in ["\"count\":1,","\"\\u0063ount\":1,"] {
        try rejected("duplicate "+extra,[Data(("{"+extra+begin.dropFirst()).utf8)])
    }
    for path in ["../x","/x","a//b","a/./b","a\\b","e\u{301}",".env",".git/a","x/credentials","x.key",String(repeating:"a",count:256),String(repeating:"a/",count:16)+"x"] {
        var f=try JSONSerialization.jsonObject(with:messages[1]) as! [String:Any];f["path"]=path
        try rejected("path-"+String(labels.count),[messages[0],try frame(f)])
    }
    for files in [["A":data,"a":data],["Dir/a":data,"dir/b":data],["a":data,"a/b":data]] {
        try rejected("collision-"+String(labels.count),try WorkspaceTransferWire.messages(files))
    }
    for kind in ["symlink","fifo","directory"] {
        try rejected("type "+kind,[messages[0],try frame(["v":1,"type":kind,"seq":1,"path":"bad"])])
    }
    var file=try JSONSerialization.jsonObject(with:messages[1]) as! [String:Any]
    file["size"]=4*1024*1024+1
    try rejected("file size",[messages[0],try frame(file)])
    for (name,field,value) in [("entry count","count",1001),("aggregate","total",16*1024*1024+1)] {
        var f=try JSONSerialization.jsonObject(with:messages[0]) as! [String:Any];f[field]=value
        try rejected(name,[try frame(f)])
    }
    var chunk=try JSONSerialization.jsonObject(with:messages[2]) as! [String:Any]
    chunk["offset"]=1
    try rejected("chunk order",[messages[0],messages[1],try frame(chunk)])
    try rejected("chunk replay",[messages[0],messages[1],messages[2],messages[2]])
    chunk["offset"]=0;chunk["data"]=Data(repeating:0,count:4097).base64EncodedString()
    try rejected("chunk overflow",[messages[0],messages[1],try frame(chunk)])
    chunk["data"]=Data(repeating:0,count:data.count).base64EncodedString()
    try rejected("file digest",[messages[0],messages[1],try frame(chunk),messages[3]])
    var complete=try JSONSerialization.jsonObject(with:messages.last!) as! [String:Any];complete["sha256"]=String(repeating:"0",count:64)
    try rejected("tree digest",Array(messages.dropLast())+[try frame(complete)])
    try rejected("early complete",[messages[0],try frame(["v":1,"type":"complete","seq":1,"sha256":WorkspaceTransferWire.hash(Data())])])
    let stopped=WorkspaceTransferReceiver();try stopped.receive(messages[0]);try stopped.receive(messages[1]);try stopped.receive(messages[2]);stopped.stop()
    do {try stopped.receive(messages[3]);throw NSError(domain:"stopped",code:1)} catch WorkspaceTransferError.rejected {}
    pass("stop clears partial")
    let root=ProcessInfo.processInfo.environment["TMPDIR"]!+"/workspace-transfer-check-"+UUID().uuidString
    try check(mkdir(root,0o700)==0,"mkdir fixture")
    try check(mkdir(root+"/source",0o700)==0,"mkdir source")
    try check(mkdir(root+"/source/empty",0o700)==0,"mkdir empty")
    let store=try WorkspaceStore(newRoot:root+"/store");let snapshot=try store.importTree(from:root+"/source")
    var rejectedEmpty=false
    do {_ = try store.transferFiles(snapshot.id)} catch WorkspaceError.rejected {rejectedEmpty=true}
    try check(rejectedEmpty,"empty directories must not silently disappear")
    pass("empty directory unsupported explicitly")
    var boundary=[String:Data]()
    for i in 0..<996 {boundary[String(format:"small%04d",i)]=Data([0])}
    for i in 0..<4 {boundary["large"+String(i)]=Data(repeating:0,count:4*1024*1024-249)}
    let maximum=WorkspaceTransferReceiver()
    for body in try WorkspaceTransferWire.messages(boundary) {try maximum.receive(body)}
    let boundaryResult=try maximum.snapshot()
    try check(boundaryResult.files == boundary,"default entry/byte limits remain supported")
    pass("1000 files exact 16MiB")
    // A rejected transfer must not create even an empty quarantine: the receiving
    // store's limits, not the larger wire defaults, govern pre-materialization.
    var preflightFailures = [String]()
    for kind in ["fileBytes", "totalBytes", "entries", "depth", "pathBytes"] {
        var limits = WorkspaceLimits()
        let files: [String: Data]
        switch kind {
        case "fileBytes": limits.fileBytes = 1; files = ["a": Data(repeating: 0, count: 1024)]
        case "totalBytes": limits.totalBytes = 1; files = ["a": Data(repeating: 0, count: 1024)]
        case "entries": limits.entries = 1; files = ["a/b": Data([0])]
        case "depth": limits.depth = 1; files = ["a/b/c": Data([0])]
        default: limits.pathBytes = 1; files = ["ab": Data([0])]
        }
        let base = root + "/lower-" + kind
        try check(mkdir(base, 0o700) == 0, "lower fixture")
        try check(mkdir(base + "/source", 0o700) == 0, "lower source")
        let limited = try WorkspaceStore(newRoot: base + "/store", limits: limits)
        let original = try limited.importTree(from: base + "/source")
        var denied = false
        do { _ = try limited.acceptTransfer(FrozenWorkspaceTransfer(files: files, sha256: WorkspaceTransferWire.treeHash(files)), for: original.id) }
        catch WorkspaceError.rejected { denied = true }
        catch WorkspaceTransferError.rejected { denied = true }
        let children = try FileManager.default.contentsOfDirectory(atPath: base + "/store")
        let quarantines = children.filter { $0.hasPrefix("quarantine-") }
        var actualBytes = 0
        for name in quarantines {
            let enumerator = FileManager.default.enumerator(atPath: base + "/store/" + name)!
            while let path = enumerator.nextObject() as? String {
                let attrs = try FileManager.default.attributesOfItem(atPath: base + "/store/" + name + "/" + path)
                if attrs[.type] as? FileAttributeType == .typeRegular { actualBytes += attrs[.size] as! Int }
            }
        }
        print("MEASURE preflight=\(kind) actualDiskBytes=\(actualBytes) quarantineDirectories=\(quarantines.count)"); fflush(stdout)
        let oldFiles = try limited.transferFiles(original.id)
        if !denied || !quarantines.isEmpty || actualBytes != 0 || !oldFiles.isEmpty { preflightFailures.append(kind) }
    }
    try check(preflightFailures.isEmpty, "pre-materialization lower limits: " + preflightFailures.joined(separator: ","))
    pass("R2 lower effective limits before quarantine")
    // VM completion is not workflow completion. Exercise the actual finish path
    // without launching a VM; these sources belong only to this fixture probe.
    let finishing = AgentRuntimeProbe()
    finishing.workspace = try WorkspaceTransferFlow(files: [:])
    let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: finishing.queue)
    signalSource.setEventHandler {}
    signalSource.resume()
    finishing.signals = [signalSource]
    finishing.finish(0)
    let signalsRetained = !finishing.signals.isEmpty
    signalSource.cancel()
    var requestedCancel = false
    let cancellationStore = try WorkspaceStore(newRoot: root + "/cancel-latch", cancelled: { requestedCancel })
    let cancellationSnapshot = try cancellationStore.importTree(from: root + "/source")
    let cancellationReview = try cancellationStore.review(cancellationSnapshot.id)
    requestedCancel = true
    do { _ = try cancellationStore.review(cancellationSnapshot.id); throw NSError(domain: "cancel not observed", code: 1) }
    catch WorkspaceError.cancelled {}
    requestedCancel = false // A transient observer must not revive the old workflow.
    var latchRejected = false
    do { try cancellationStore.exportReviewed(cancellationReview, toNewDirectory: root + "/cancel-latch-export") }
    catch WorkspaceError.cancelled { latchRejected = true }
    print("MEASURE signalsRetained=\(signalsRetained) cancellationLatched=\(latchRejected)"); fflush(stdout)
    try check(signalsRetained && latchRejected, "VM finish/observed cancellation must survive through export")
    pass("R2 VM finish and observed cancellation remain latched")
    var low = WorkspaceLimits(); low.fileBytes = 2; low.totalBytes = 3
    for size in [1, 2, 3] {
        let r = WorkspaceTransferReceiver(limits: low)
        var denied = false
        do { for f in try WorkspaceTransferWire.messages(["a": Data(repeating: 1, count: size)]) { try r.receive(f) } }
        catch WorkspaceTransferError.rejected { denied = true }
        try check(denied == (size > 2), "effective file limit boundary")
        try check(r.acceptedBytes == (size > 2 ? 0 : size), "rejected declared size allocated bytes")
    }
    pass("R2 receiver lower limit minus/exact/plus")
    let shared = WorkspaceTransferBudget(capacity: 3)
    let held = WorkspaceTransferReceiver(limits: low, budget: shared)
    let two = try WorkspaceTransferWire.messages(["a": Data([1, 2])])
    for f in two.prefix(3) { try held.receive(f) }
    let blocked = WorkspaceTransferReceiver(limits: low, budget: shared)
    do { for f in two { try blocked.receive(f) }; throw NSError(domain: "shared budget overcommit", code: 1) }
    catch WorkspaceTransferError.rejected {}
    try check(held.acceptedBytes == 2 && blocked.acceptedBytes == 0 && shared.metrics.used == 2 && shared.metrics.reserved == 0, "shared allocation accounting")
    held.stop()
    try check(shared.metrics.used == 0 && shared.metrics.released == 2, "cancel releases actual allocation")
    let recovered = WorkspaceTransferReceiver(limits: low, budget: shared)
    for f in two { try recovered.receive(f) }
    var retained: FrozenWorkspaceTransfer? = try recovered.snapshot()
    recovered.stop()
    try check(shared.metrics.used == 2 && retained?.files["a"] == Data([1, 2]), "frozen value retains its reservation")
    retained = nil
    try check(shared.metrics.used == 0 && shared.metrics.reserved == 0 && shared.metrics.peak <= 3, "snapshot release restores capacity")
    print("MEASURE acceptedBytes=\(shared.metrics.accepted) reservationReleased=\(shared.metrics.released) peakPayloadBytes=\(shared.metrics.peak)")
    pass("R2 shared reservations rejection cancellation snapshot recovery")
    var stopAfterDiskRead = false
    let rollbackStore = try WorkspaceStore(newRoot: root + "/rollback-store", cancelled: { stopAfterDiskRead }, didReadChunk: { _ in stopAfterDiskRead = true })
    let rollbackSnapshot = try rollbackStore.importTree(from: root + "/lower-fileBytes/source")
    let diskFiles = ["a": Data(repeating: 1, count: 8192)]
    do {
        _ = try rollbackStore.acceptTransfer(FrozenWorkspaceTransfer(files: diskFiles, sha256: WorkspaceTransferWire.treeHash(diskFiles)), for: rollbackSnapshot.id)
        throw NSError(domain: "post-write cancellation accepted", code: 1)
    } catch WorkspaceError.cancelled {}
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root + "/rollback-store").filter { $0.hasPrefix("quarantine-") }
    print("MEASURE cancelledQuarantines=\(leftovers.count)"); fflush(stdout)
    try check(leftovers.isEmpty, "cancelled owned quarantine must release disk capacity")
    pass("R2 post-write cancellation removes only owned quarantine")
    try check(rollbackStore.transferDiskBudget.metrics.accepted == 8192 && rollbackStore.transferDiskBudget.metrics.used == 0 && rollbackStore.transferDiskBudget.metrics.reserved == 0 && rollbackStore.transferDiskBudget.metrics.released == 8192, "actual disk bytes and release")
    print("MEASURE diskWritten=\(rollbackStore.transferDiskBudget.metrics.accepted) temporaryDiskPeak=\(rollbackStore.transferDiskBudget.metrics.peak) diskReleased=\(rollbackStore.transferDiskBudget.metrics.released)")
    for reported in [1, 3] {
        let r = WorkspaceTransferReceiver()
        var wire = two
        var begin = try JSONSerialization.jsonObject(with: wire[0]) as! [String: Any]
        var header = try JSONSerialization.jsonObject(with: wire[1]) as! [String: Any]
        begin["total"] = reported; header["size"] = reported
        wire[0] = try frame(begin); wire[1] = try frame(header)
        do { for f in wire { try r.receive(f) }; throw NSError(domain: "declared/actual mismatch accepted", code: 1) }
        catch WorkspaceTransferError.rejected {}
        try check(r.acceptedBytes == (reported == 1 ? 0 : 2) && r.budget.metrics.used == 0 && r.budget.metrics.reserved == 0, "mismatch before growth or released on truncation")
    }
    let overflow = WorkspaceTransferReservation(shared)
    do { try overflow.reserve(Int.max); throw NSError(domain: "overflow reservation", code: 1) }
    catch WorkspaceTransferError.rejected {}
    pass("R2 declared actual mismatch and overflow-safe reservation")
    let racingBudget = WorkspaceTransferBudget(capacity: 3)
    let attempts = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let workers = DispatchGroup()
    for _ in 0..<2 {
        workers.enter()
        DispatchQueue.global().async {
            let r = WorkspaceTransferReceiver(budget: racingBudget)
            do { for f in two { try r.receive(f) } } catch {}
            attempts.signal()
            _ = release.wait(timeout: .now() + 5)
            r.stop(); workers.leave()
        }
    }
    let arrived1 = attempts.wait(timeout: .now() + 5), arrived2 = attempts.wait(timeout: .now() + 5)
    let atCapacity = racingBudget.metrics
    release.signal(); release.signal()
    let settled = workers.wait(timeout: .now() + 5)
    try check(arrived1 == .success && arrived2 == .success && settled == .success, "concurrent barrier settled")
    try check(atCapacity.accepted == 2 && atCapacity.used == 2 && atCapacity.reserved == 0 && racingBudget.metrics.used == 0 && racingBudget.metrics.released == 2, "concurrent reservation excludes overcommit")
    let reuse = WorkspaceTransferReceiver(budget: racingBudget)
    for f in two { try reuse.receive(f) }; reuse.stop()
    try check(racingBudget.metrics.accepted == 4 && racingBudget.metrics.used == 0, "fresh channel reuses capacity")
    pass("R2 concurrent receivers shared capacity and recovery")
    for stage in ["beforeReceive", "beforeReview", "beforeExport", "beforeRename", "afterRename", "unverified"] {
        let latch = WorkspaceExportCancellation()
        let s = try WorkspaceStore(newRoot: root + "/stage-" + stage, cancellation: latch)
        let snap = try s.importTree(from: root + "/lower-fileBytes/source")
        let result = FrozenWorkspaceTransfer(files: ["a": Data([1, 2])], sha256: WorkspaceTransferWire.treeHash(["a": Data([1, 2])]))
        let destination = root + "/export-" + stage
        if stage == "beforeReceive" {
            latch.cancel()
            do { _ = try s.acceptTransfer(result, for: snap.id); throw NSError(domain: "cancel receive", code: 1) } catch WorkspaceError.cancelled {}
        } else {
            _ = try s.acceptTransfer(result, for: snap.id)
            if stage == "beforeReview" {
                latch.cancel()
                do { _ = try s.review(snap.id); throw NSError(domain: "cancel review", code: 1) } catch WorkspaceError.cancelled {}
            } else {
                let review = try s.review(snap.id)
                if stage == "beforeExport" { latch.cancel() }
                var relocationSucceeded = false
                s.exportBoundary = { boundary in
                    if stage == "beforeRename", boundary == .beforeRename { latch.cancel() }
                    if stage == "afterRename", boundary == .afterRename { latch.cancel() }
                    if stage == "unverified", boundary == .afterRename { relocationSucceeded = rename(destination, destination + "-moved") == 0 }
                }
                if stage == "afterRename" {
                    try s.exportReviewed(review, toNewDirectory: destination)
                    try check(latch.isCancelled && FileManager.default.fileExists(atPath: destination + "/a"), "commit wins and files survive cancellation")
                    s.exportBoundary = nil
                    let independent = WorkspaceExportCancellation()
                    try s.exportReviewedAfterStop(review, toNewDirectory: destination + "-approved", actionCancellation: independent)
                    try check(latch.isCancelled, "separate action must not clear old workflow")
                    do { try s.exportReviewed(review, toNewDirectory: destination + "-retry"); throw NSError(domain: "old workflow revived", code: 1) } catch WorkspaceError.cancelled {}
                } else if stage == "unverified" {
                    do { try s.exportReviewed(review, toNewDirectory: destination); throw NSError(domain: "unverified commit hidden", code: 1) } catch WorkspaceError.committedUnverified {}
                    try check(relocationSucceeded && FileManager.default.fileExists(atPath: destination + "-moved/a"), "committed-unverified must not delete files")
                } else {
                    do { try s.exportReviewed(review, toNewDirectory: destination); throw NSError(domain: "cancel export", code: 1) } catch WorkspaceError.cancelled {}
                    latch.cancel()
                }
            }
        }
        if stage != "afterRename" { try check(!FileManager.default.fileExists(atPath: destination), "no publication before commit") }
        try check(s.transferDiskBudget.metrics.used == 0 && s.transferDiskBudget.metrics.reserved == 0 && s.transferDiskBudget.metrics.orphaned == 0, "temporary disk released after terminal stage")
        pass("R2 cancellation stage " + stage)
    }
    let writeCancel = WorkspaceExportCancellation()
    let chunkStore = try WorkspaceStore(newRoot: root + "/chunk-cancel", cancellation: writeCancel)
    let chunkSnapshot = try chunkStore.importTree(from: root + "/lower-fileBytes/source")
    chunkStore.didWriteTransferChunk = { _ in writeCancel.cancel() }
    do { _ = try chunkStore.acceptTransfer(FrozenWorkspaceTransfer(files: diskFiles, sha256: WorkspaceTransferWire.treeHash(diskFiles)), for: chunkSnapshot.id); throw NSError(domain: "write cancel", code: 1) } catch WorkspaceError.cancelled {}
    try check(chunkStore.transferDiskBudget.metrics.accepted == 4096 && chunkStore.transferDiskBudget.metrics.used == 0 && chunkStore.transferDiskBudget.metrics.reserved == 0, "cancel stops at actual written chunk and releases reservation")
    try check(chunkStore.transferDiskBudget.metrics.peakUsed == 4096 && chunkStore.transferDiskBudget.metrics.peak == 8192, "actual disk peak differs from reserved peak")
    print("MEASURE cancelledWriteBytes=\(chunkStore.transferDiskBudget.metrics.accepted) actualDiskPeak=\(chunkStore.transferDiskBudget.metrics.peakUsed) reservedPeak=\(chunkStore.transferDiskBudget.metrics.peak) reservedReleased=\(chunkStore.transferDiskBudget.metrics.released)")
    pass("R2 cancellation during actual disk chunks")
    for kind in ["total", "entries", "depth", "path"] {
        for amount in [1, 2, 3] {
            var cap = WorkspaceLimits()
            let files: [String: Data]
            switch kind {
            case "total": cap.totalBytes = 2; files = ["a": Data(repeating: 1, count: amount)]
            case "entries": cap.entries = 2; files = [Array(repeating: "a", count: amount).joined(separator: "/"): Data([1])]
            case "depth": cap.depth = 1; files = [Array(repeating: "a", count: amount).joined(separator: "/"): Data([1])]
            default: cap.pathBytes = 2; files = [String(repeating: "a", count: amount): Data([1])]
            }
            let base = root + "/exact-" + kind + String(amount)
            let s = try WorkspaceStore(newRoot: base, limits: cap)
            let snap = try s.importTree(from: root + "/lower-fileBytes/source")
            var denied = false
            do { _ = try s.acceptTransfer(FrozenWorkspaceTransfer(files: files, sha256: WorkspaceTransferWire.treeHash(files)), for: snap.id) }
            catch WorkspaceTransferError.rejected { denied = true }
            try check(denied == (amount == 3), "host effective exact boundary " + kind)
            let metrics = s.transferDiskBudget.metrics
            try check(metrics.accepted == (amount == 3 ? 0 : files.values.reduce(0) { $0 + $1.count }) && metrics.used == 0 && metrics.reserved == 0, "exact accepted/written/released " + kind)
        }
        pass("R2 host exact boundaries " + kind)
    }
    var nestedStore: WorkspaceStore!
    var nestedID: WorkspaceSnapshotID?
    var armNested = false, nestedRejected = false
    let oldCancellation = WorkspaceExportCancellation()
    nestedStore = try WorkspaceStore(newRoot: root + "/independent-scope", cancellation: oldCancellation, didReadChunk: { _ in
        if armNested {
            armNested = false
            do { _ = try nestedStore.review(nestedID!) } catch WorkspaceError.cancelled { nestedRejected = true }
        }
    })
    let nestedSnapshot = try nestedStore.importTree(from: root + "/lower-fileBytes/source")
    nestedID = nestedSnapshot.id
    let nestedFiles = ["a": Data([1])]
    _ = try nestedStore.acceptTransfer(FrozenWorkspaceTransfer(files: nestedFiles, sha256: WorkspaceTransferWire.treeHash(nestedFiles)), for: nestedSnapshot.id)
    let nestedReview = try nestedStore.review(nestedSnapshot.id)
    oldCancellation.cancel(); armNested = true
    try nestedStore.exportReviewedAfterStop(nestedReview, toNewDirectory: root + "/independent-scope-export", actionCancellation: WorkspaceExportCancellation())
    try check(nestedRejected && oldCancellation.isCancelled, "independent export must not temporarily revive other old workflow calls")
    pass("R2 independent action never revives nested old workflow")
    return (root, labels)
 }
}
