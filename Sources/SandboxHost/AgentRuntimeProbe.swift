import Foundation
import CryptoKit
@preconcurrency import Virtualization
import Darwin

/// Standalone runtime acceptance harness. Queue/FD teardown follows HeadlessVMProbe.
/// Not an App grant, model broker, import/export API, or diagnostic protocol replacement.
final class AgentRuntimeProbe: NSObject, VZVirtioSocketListenerDelegate, VZVirtualMachineDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "runtime-v1")
    let completion = DispatchSemaphore(value: 0)
    var vm: VZVirtualMachine?; var device: VZVirtioSocketDevice?; var listener: VZVirtioSocketListener?
    var connection: VZVirtioSocketConnection?; var console: Pipe?; var timer: DispatchSourceTimer?
    var signals: [DispatchSourceSignal] = []
    var startPending = false, stopPending = false, stopping = false, stopIssued = false, finished = false, failed = false
    var input = Data(), output = Data(); var frames = 0, outputBytes = 0, consoleBytes = 0, command = 0
    var end = 0.0, stopEnd = 0.0; var didCancel = false
    var exitCode: Int32 = 1
    var now: Double { ProcessInfo.processInfo.systemUptime }
    var vendorDisk: URL? = nil
    var commands: [[String]] = [
        ["/usr/bin/node", "-e", "console.log(process.version);console.error('synthetic-stderr-channel')"], ["/usr/bin/python3", "--version"], ["/usr/bin/git", "--version"],
        ["/usr/bin/python3", "-B", "task.py"],
        ["/usr/bin/python3", "-c", "import time; print('cancel-ready',flush=True); time.sleep(30)"],
        ["/usr/bin/python3", "-c", "import pathlib,hashlib; p=pathlib.Path('logic.py'); assert b'return a + b' in p.read_bytes(); assert pathlib.Path('/work/session-marker').read_text()=='private-session-write'; print('same-VM-isolation-check',hashlib.sha256(p.read_bytes()).hexdigest())"],
        // Guest-only regression: child stays in our owned group after leader/pipe exit.
        ["/usr/bin/python3", "-c", "import os,time,pathlib; r,w=os.pipe(); pid=os.fork()\nif pid==0:\n os.close(r); os.close(1); os.close(2); os.write(w,b'R'); os.close(w); time.sleep(30); os._exit(0)\nos.close(w); assert os.read(r,1)==b'R'; pathlib.Path('/work/descendant-group').write_text(str(os.getpgrp())); print('descendant-ready',flush=True)"],
        ["/usr/bin/python3", "-c", "import os,pathlib; group=int(pathlib.Path('/work/descendant-group').read_text())\ntry: os.killpg(group,0)\nexcept ProcessLookupError: print('owned-group-reaped')\nelse: raise AssertionError('owned descendant survived leader and pipe exit')"]
    ]
    func event(_ type: String, _ detail: [String: Any] = [:]) {
        var d = detail; d["event"] = type
        if let b = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]), let s = String(data:b,encoding:.utf8) { print(s); fflush(stdout) }
    }
    func run(kernel: URL, ramdisk: URL, disk: URL) -> Int32 {
        queue.async { self.start(kernel:kernel,ramdisk:ramdisk,disk:disk) }
        if completion.wait(timeout:.now()+(vendorDisk == nil ? 82:112)) != .success { event("outerTimeout",["stopped":"UNKNOWN"]); return 1 }
        return queue.sync { exitCode }
    }
    func start(kernel: URL, ramdisk: URL, disk: URL) {
        end=now+(vendorDisk == nil ? 65:95)
        do {
            let c=VZVirtualMachineConfiguration(); c.platform=VZGenericPlatformConfiguration()
            let boot=VZLinuxBootLoader(kernelURL:kernel);boot.initialRamdiskURL=ramdisk;boot.commandLine="console=hvc0 rdinit=/init"
            c.bootLoader=boot;c.cpuCount=2;c.memorySize=1073741824
            c.networkDevices=[];c.directorySharingDevices=[]
            c.storageDevices=[VZVirtioBlockDeviceConfiguration(attachment:try VZDiskImageStorageDeviceAttachment(url:disk,readOnly:false,cachingMode:.uncached,synchronizationMode:.full))]
            if let vendorDisk { c.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment:try VZDiskImageStorageDeviceAttachment(url:vendorDisk,readOnly:true,cachingMode:.uncached,synchronizationMode:.full))) }
            c.socketDevices=[VZVirtioSocketDeviceConfiguration()]
            let p=Pipe();console=p
            guard fcntl(p.fileHandleForReading.fileDescriptor,F_SETFL,O_NONBLOCK) != -1 else { throw Failure.io }
            let serial=VZVirtioConsoleDeviceSerialPortConfiguration();serial.attachment=VZFileHandleSerialPortAttachment(fileHandleForReading:nil,fileHandleForWriting:p.fileHandleForWriting);c.serialPorts=[serial]
            try c.validate(); let machine=VZVirtualMachine(configuration:c,queue:queue);vm=machine;machine.delegate=self
            guard let d=machine.socketDevices.first as? VZVirtioSocketDevice else { throw Failure.identity }
            device=d;let l=VZVirtioSocketListener();listener=l;l.delegate=self;d.setSocketListener(l,forPort:4060)
            event("configuration",["NIC":c.networkDevices.count,"shares":c.directorySharingDevices.count,"privateDisks":c.storageDevices.count,"RAM":c.memorySize,"CPUs":c.cpuCount,"controlPort":4060])
            let t=DispatchSource.makeTimerSource(queue:queue);timer=t;t.schedule(deadline:.now(),repeating:.milliseconds(10));t.setEventHandler{[weak self] in self?.tick()};t.resume()
            for n in [SIGINT,SIGTERM] { signal(n,SIG_IGN);let s=DispatchSource.makeSignalSource(signal:n,queue:queue);s.setEventHandler{[weak self] in self?.stop(true,"hostCancel")};s.resume();signals.append(s) }
            startPending=true;event("vm.start")
            machine.start { result in
                self.startPending=false
                switch result { case .success:self.event("start.callback"); case .failure(let e):self.event("start.failed",["error":String(describing:e)]);self.stop(true,"startFailed") }
                if self.stopping {self.progressStop()}
            }
        } catch { event("preparation.failed",["error":String(describing:error)]);stop(true,"prepare") }
    }
    enum Failure: Error { case io, identity, frame, order, budget, digest }
    func listener(_ listener:VZVirtioSocketListener,shouldAcceptNewConnection new:VZVirtioSocketConnection,from socket:VZVirtioSocketDevice)->Bool {
        guard !stopping, self.listener === listener, device === socket, connection == nil, command == 0 else { new.close(); return false }
        var one:Int32=1
        guard fcntl(new.fileDescriptor,F_SETFL,O_NONBLOCK) != -1,setsockopt(new.fileDescriptor,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))==0 else {new.close();return false}
        connection=new;event("accepted",["binding":"actual VZVirtioSocketDevice object; no guest identity lookup"]);return true
    }
    func send(_ type:String,_ id:Int,_ extra:[String:Any]=[:]) throws {
        guard !stopping else {throw Failure.order}
        var d=extra;d["v"]=1;d["type"]=type;d["id"]=id
        let b=try JSONSerialization.data(withJSONObject:d,options:[.sortedKeys]);guard b.count<=16384,output.count+4+b.count<=32768 else {throw Failure.budget}
        var size=UInt32(b.count).bigEndian;withUnsafeBytes(of:&size){output.append(contentsOf:$0)};output.append(b)
    }
    func next() throws {
        command+=1
        if command>commands.count {stop(false,"commandsComplete");return}
        event("host.launch",["id":command,"argv":commands[command-1]])
        try send("launch",command,["argv":commands[command-1]])
    }
    func receive(_ data:Data) throws {
        try validateRuntimeFrame(data)
        guard let f=try JSONSerialization.jsonObject(with:data) as? [String:Any],f["v"] as? Int==1,let kind=f["type"] as? String,let id=f["id"] as? Int else {throw Failure.frame}
        if kind=="hello" {
            guard command==0,id==0,f["fresh"] as? Bool==true,f["interfaces"] as? [String]==["lo"] else {throw Failure.order}
            event("guest.hello",f);try next();return
        }
        guard id==command,command>0 else {throw Failure.order}
        switch kind {
        case "stdout","stderr":
            guard let s=f["data"] as? String,let b=Data(base64Encoded:s),b.count<=4096,let h=f["sha256"] as? String else {throw Failure.frame}
            let digest=SHA256.hash(data:b).map{String(format:"%02x",$0)}.joined();guard digest==h else {throw Failure.digest}
            outputBytes+=b.count;guard outputBytes<=262144 else {throw Failure.budget}
            event("guest."+kind,f)
            if command==5 && !didCancel { didCancel=true;try send("cancel",5);event("host.cancel",["id":5]) }
        case "exit":
            guard let code=f["code"] as? Int,let cancelled=f["cancelled"] as? Bool else {throw Failure.frame}
            guard command==5 ? (code == -9 && cancelled && didCancel) : (code==0 && !cancelled) else {throw Failure.order}
            event("guest.exit",f);try next()
        default:throw Failure.frame
        }
    }
    func ingest(_ bytes:Data) throws {
        guard !stopping else {throw Failure.order}
        guard input.count+bytes.count<=16388 else{throw Failure.budget};input.append(bytes)
        // At most one socket read per turn; total accepted frames and bytes are separately bounded.
        while input.count>=4 {
            let size=input.prefix(4).reduce(0){($0<<8)|Int($1)};guard size>0,size<=16384 else{throw Failure.frame}
            if input.count<4+size{break}
            let body=Data(input.dropFirst(4).prefix(size));input.removeFirst(4+size);frames+=1;guard frames<=512 else{throw Failure.budget}
            try receive(body);if stopping{return}
        }
    }
    func tick() {
        if finished{return};if stopping{progressStop();return};if now>=end{stop(true,"runtimeDeadline");return}
        do {
            if let p=console {
                var b=[UInt8](repeating:0,count:4096);let n=Darwin.read(p.fileHandleForReading.fileDescriptor,&b,b.count)
                if n>0 && consoleBytes<65536 {consoleBytes+=n;if vendorDisk == nil {event("console",["base64":Data(b.prefix(n)).base64EncodedString()])}}
            }
            guard let c=connection else{return}
            if !output.isEmpty {
                let n=output.withUnsafeBytes{Darwin.write(c.fileDescriptor,$0.baseAddress,$0.count)}
                if n>0{output.removeFirst(n)}else if n<0 && errno != EAGAIN && errno != EINTR{throw Failure.io}
            }
            var b=[UInt8](repeating:0,count:4096);let n=Darwin.read(c.fileDescriptor,&b,b.count)
            if n==0{throw Failure.io};if n<0{if errno != EAGAIN && errno != EINTR{throw Failure.io};return}
            try ingest(Data(b.prefix(n)))
        }catch{event("protocol.failed",["error":String(describing:error)]);stop(true,"protocol")}
    }
    func stop(_ failure:Bool,_ reason:String) {
        failed=failed || failure;guard !stopping else{return};stopping=true;stopEnd=now+10
        device?.removeSocketListener(forPort:4060);listener=nil;connection?.close();connection=nil;output.removeAll();input.removeAll()
        event("vm.stopping",["reason":reason]);progressStop()
    }
    func progressStop() {
        guard !finished else{return}
        if let p=console {var b=[UInt8](repeating:0,count:4096);_ = Darwin.read(p.fileHandleForReading.fileDescriptor,&b,b.count)}
        guard let m=vm else{finish(1);return}
        if m.state == .stopped && !startPending && !stopPending {
            event("vm.stopped",["actualState":"stopped","startPending":false,"stopPending":false])
            try? console?.fileHandleForReading.close();try? console?.fileHandleForWriting.close();console=nil
            event("console.released");finish(failed ? 1:0);return
        }
        if now>=stopEnd{event("stopTimeout",["actualState":m.state.rawValue,"startPending":startPending,"stopPending":stopPending]);finish(1);return}
        if !startPending && !stopIssued && m.canStop {
            stopIssued=true;stopPending=true
            m.stop {error in self.stopPending=false;if error != nil{self.failed=true};self.event("stop.callback");self.progressStop()}
        }
    }
    func finish(_ code:Int32) {guard !finished else{return};finished=true;exitCode=code;timer?.cancel();for s in signals{s.cancel()};signals=[];event("result",["exitCode":code,"commands":min(command,commands.count),"frames":frames,"outputBytes":outputBytes]);completion.signal()}
    func guestDidStop(_ virtualMachine:VZVirtualMachine){stop(!stopping,"guestStopped")}
    func virtualMachine(_ virtualMachine:VZVirtualMachine,didStopWithError error:Error){stop(true,"frameworkError")}
}
