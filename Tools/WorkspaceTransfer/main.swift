import Foundation
import Darwin
import SandboxContracts

// Deliberately not a product entry point: the only selectable input is a newly
// created synthetic fixture, and the only export is a NEW fixture directory.
func require(_ yes: Bool) throws { if !yes { throw WorkspaceTransferError.rejected } }
func directory(_ path:String) throws {
    try require(path.hasPrefix("/") && !path.split(separator:"/").contains(where:{$0=="." || $0==".."}))
    var url=URL(fileURLWithPath:path);var leaf=true
    while true {
        var st=stat();try require(lstat(url.path,&st)==0 && st.st_mode&S_IFMT==S_IFDIR && (st.st_uid==0 || st.st_uid==geteuid()) && st.st_mode&0o022==0)
        if leaf {try require(st.st_uid==geteuid() && st.st_mode&0o077==0);leaf=false}
        if url.path=="/" {break};url.deleteLastPathComponent()
    }
}
func regular(_ path:String,_ max:Int) throws -> Data {
    let fd=open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);try require(fd>=0);defer{close(fd)}
    var st=stat();try require(fstat(fd,&st)==0 && st.st_mode&S_IFMT==S_IFREG && st.st_nlink==1 && st.st_uid==geteuid() && st.st_mode&0o022==0 && st.st_size<=max)
    var result=Data();var buf=[UInt8](repeating:0,count:65536)
    while true {let n=read(fd,&buf,min(buf.count,max+1-result.count));if n==0{break};try require(n>0 && result.count+n<=max);result.append(contentsOf:buf.prefix(n))}
    return result
}
func writeNew(_ path:String,_ bytes:Data) throws {
    let fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);try require(fd>=0);defer{close(fd)}
    try bytes.withUnsafeBytes { raw in
        var offset=0
        while offset<raw.count {let n=write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset);try require(n>0);offset+=n}
    }
}
@main struct WorkspaceFixtureDriver {
 static func main() async {
    do {
        let args=CommandLine.arguments;try require(args.count==4 && ["normal","cancel","cancel-after-vm","cancel-before-rename","cancel-after-rename"].contains(args[3]))
        let image=args[1],session=args[2];try directory(image);try directory(session)
        let probe=AgentRuntimeProbe()
        defer { probe.finishWorkspaceWorkflow() }
        let store=try WorkspaceStore(newRoot:session+"/store", cancellation: probe.workspaceCancellation) // validates trusted ancestry/ACL
        let manifest=try JSONSerialization.jsonObject(with:regular(image+"/runtime.json",4*1024*1024)) as? [String:Any]
        try require(manifest?["workspaceProfile"] as? String == "workspace-fixture-v1" && manifest?["agentProbeProfile"] == nil)
        try require(WorkspaceTransferWire.hash(try regular(image+"/Image",64*1024*1024))=="256d5fff4bb892edcb9218c1e6353e388bc3646e65f76c2bc9d958b635d1b00e")
        try require(WorkspaceTransferWire.hash(try regular(image+"/runtime.cpio.gz",128*1024*1024))==manifest?["initramfsSHA256"] as? String)
        let source=session+"/synthetic-source";try require(mkdir(source,0o700)==0)
        let fixture:[String:Data]=[
            "logic.py":Data("def add(a, b):\n    return a - b\n".utf8),
            "test_logic.py":Data("from logic import add\nassert add(2, 3) == 5\n".utf8),
            "data.bin":Data(repeating:42,count:12288)]
        for (p,b) in fixture {try writeNew(source+"/"+p,b)}
        let snapshot=try store.importTree(from:source)
        // Real F03 installation for this synthetic fixture only. Empty connection
        // grants confer no file/model/MCP permission. Quota binding is not a permit.
        let authority = RunAuthorizationController(auditSink: try JSONLAuditSink(newFileAt: URL(fileURLWithPath: session + "/quota-audit.jsonl")))
        let now = Date()
        let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: now, expiresAt: now.addingTimeInterval(300),
            workloadImageDigest: manifest!["initramfsSHA256"] as! String, agentAdapterVersion: "workspace-fixture-v1",
            workspaceSnapshotID: snapshot.id.grantSnapshotID,
            policyDigest: WorkspaceTransferWire.hash(Data("synthetic-workspace-quota-fixture-only-v1".utf8)),
            approvalSnapshotID: UUID(), connections: [], explicitDenies: [],
            resourceLimits: ResourceLimits(cpuCount: 2, memoryBytes: 1073741824, diskBytes: 67108864, messageBytes: 16384, concurrentRequests: 1))
        let handle = try await authority.install(grant: grant)
        let quota = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: handle, grant: grant)
        try store.bindTransferQuota(quota, for: snapshot.id)
        // New, explicitly host-owned task policy, not retroactive RunGrant fields.
        let task = try store.createTransferTask(for: snapshot.id, limits: WorkspaceTaskLimits(
            retainedPayloadBytes: 1024 * 1024, diskBytes: 1024 * 1024, cumulativeInputBytes: 4 * 1024 * 1024))
        func taskMetrics() {
            let memory = task.memory.metrics, disk = task.disk.metrics
            probe.event("workspace.taskMetrics", ["input":memory.accepted,"payloadCurrent":memory.used,"payloadReserved":memory.reserved,
                "diskCurrent":disk.used,"diskReserved":disk.reserved,"diskCommitted":disk.committed,"diskWritten":disk.accepted,
                "diskPeak":disk.peakUsed,"diskReservedPeak":disk.peak,"diskReleased":disk.released,"diskOrphaned":disk.orphaned])
        }
        probe.event("workspace.quota", ["installedF03":true,"snapshotMatched":true,"fixtureOnly":true,"messageBytes":quota.messageBytes,"hostTask":true])
        let outbound=try store.transferFiles(snapshot.id)
        try require(outbound==fixture)
        let disk=session+"/private.raw";let fd=open(disk,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);try require(fd>=0)
        let resized=ftruncate(fd,67108864);close(fd);try require(resized==0)
        let flow=try store.transferFlow(for:snapshot.id);flow.cancelOnChunk=args[3]=="cancel";probe.workspace=flow
        let code=probe.run(kernel:URL(fileURLWithPath:image+"/Image"),ramdisk:URL(fileURLWithPath:image+"/runtime.cpio.gz"),disk:URL(fileURLWithPath:disk))
        for (path, bytes) in fixture { try require(try regular(source+"/"+path,4*1024*1024)==bytes) }
        if args[3]=="cancel" {
            try require(code==1 && probe.workspaceResult==nil && flow.receiver.poisoned && !FileManager.default.fileExists(atPath:session+"/export"))
            taskMetrics(); probe.event("workspace.fixture",["cancelled":true,"exported":false,"originalUnchanged":true]);return
        }
        try require(code==0)
        guard let result=probe.workspaceResult,let receipt=result.files["guest-result.json"] else {throw WorkspaceTransferError.rejected}
        let report=try RuntimeJSON.parse(receipt).object
        var tested=result.files;tested.removeValue(forKey:"guest-result.json")
        try require(report?["redExit"] == .integer(1) && report?["testExit"] == .integer(0) && report?["testedSHA256"] == .string(WorkspaceTransferWire.treeHash(tested)))
        var expected=fixture;expected["logic.py"]=Data("def add(a, b):\n    return a + b\n".utf8)
        try require(tested==expected)
        // The verifier signals only this owned child at the explicit barrier.
        func awaitHostCancel() -> Bool {
            probe.event("workspace.awaitCancel")
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !probe.workspaceCancellation.isCancelled && ProcessInfo.processInfo.systemUptime < deadline { usleep(1000) }
            return probe.workspaceCancellation.isCancelled
        }
        if args[3] == "cancel-after-vm" {
            try require(awaitHostCancel())
            do { _ = try store.acceptTransfer(result, for: snapshot.id); throw WorkspaceTransferError.rejected }
            catch WorkspaceError.cancelled {}
            try require(!FileManager.default.fileExists(atPath: session+"/export") && store.transferDiskBudget.metrics.accepted == 0)
            taskMetrics(); probe.event("workspace.fixture", ["cancelled":true,"exported":false,"afterVM":true,"originalUnchanged":true,"writtenBytes":0]);return
        }
        let quarantine=try store.acceptTransfer(result,for:snapshot.id)
        let review=try store.review(snapshot.id)
        try require(review.exclusions.isEmpty && review.changes.count==2)
        var cancelObserved = false
        store.exportBoundary = { boundary in
            if (args[3] == "cancel-before-rename" && boundary == .beforeRename) || (args[3] == "cancel-after-rename" && boundary == .afterRename) { cancelObserved = awaitHostCancel() }
        }
        // Explicit trusted fixture-only host decision; never guest-driven approval.
        if args[3] == "cancel-before-rename" {
            do { try store.exportReviewed(review,toNewDirectory:session+"/export");throw WorkspaceTransferError.rejected }
            catch WorkspaceError.cancelled {}
            try require(cancelObserved && !FileManager.default.fileExists(atPath: session+"/export") && store.transferDiskBudget.metrics.used == 0 && store.transferDiskBudget.metrics.reserved == 0)
            taskMetrics(); probe.event("workspace.fixture", ["cancelled":true,"exported":false,"beforeCommit":true,"originalUnchanged":true,"writtenBytes":store.transferDiskBudget.metrics.accepted,"diskReleased":store.transferDiskBudget.metrics.released]);return
        }
        try store.exportReviewed(review,toNewDirectory:session+"/export")
        var exported=[String:Data]()
        for p in result.files.keys {exported[p]=try regular(session+"/export/"+p,4*1024*1024)}
        try require(exported==result.files && WorkspaceTransferWire.treeHash(exported)==result.sha256)
        if args[3] == "cancel-after-rename" {
            try require(cancelObserved && probe.workspaceCancellation.isCancelled)
            do { try store.exportReviewed(review,toNewDirectory:session+"/retry");throw WorkspaceTransferError.rejected }
            catch WorkspaceError.cancelled {}
            taskMetrics(); probe.event("workspace.fixture", ["cancelled":true,"exported":true,"committed":true,"oldWorkflowRejected":true,"originalUnchanged":true,"sha256":result.sha256]);return
        }
        // Mutation of our owned fixture after review must still reject stale export.
        let changed=quarantine+"/logic.py";try require(chmod(changed,0o600)==0)
        let mutation=open(changed,O_WRONLY|O_TRUNC|O_NOFOLLOW);try require(mutation>=0)
        let byte:[UInt8]=[10];let wrote=byte.withUnsafeBytes{write(mutation,$0.baseAddress,1)};close(mutation);try require(wrote==1)
        do {try store.exportReviewed(review,toNewDirectory:session+"/stale-export");throw WorkspaceTransferError.rejected}
        catch WorkspaceError.staleReview {}
        try require(!FileManager.default.fileExists(atPath:session+"/stale-export") && (try store.originalChanges(snapshot.id)).isEmpty)
        taskMetrics(); probe.event("workspace.fixture",["guestRedExit":1,"guestTestExit":0,"originalUnchanged":true,"exportMatchesTestedBytes":true,"staleReviewRejected":true,"files":result.files.count,"sha256":result.sha256])
    } catch {print("{\"event\":\"workspace.fixture.failed\",\"error\":\"rejected\"}");exit(1)}
 }
}
