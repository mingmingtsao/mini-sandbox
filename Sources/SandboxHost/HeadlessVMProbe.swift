import Foundation
@preconcurrency import Virtualization
import Darwin

/// Queue-confined callback ownership, independent of VZ's transient state.
package struct VMProbeLifetime {
    package init() {}
    package var startPending = false
    package var stopPending = false
    package func canReleaseResources(actualStopped: Bool) -> Bool {
        actualStopped && !startPending && !stopPending
    }
}

/// All framework objects, callbacks, lifecycle and socket I/O stay on this serial queue.
public final class HeadlessVMProbe: NSObject, VZVirtioSocketListenerDelegate, VZVirtualMachineDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "mini-sandbox.vm-probe")
    private let runLock = NSLock()
    private var runClaimed = false
    private var lifetime = VMProbeLifetime()
    private var vm: VZVirtualMachine?
    private var device: VZVirtioSocketDevice?
    private var listener: VZVirtioSocketListener?
    private var connection: VZVirtioSocketConnection?
    private var session: VMDiagnosticSession?
    private var console: Pipe?
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var parser = VMFrameParser()
    private var output = Data()
    private var connectionDeadline = 0.0
    private var runDeadline = 0.0
    private var stopDeadline = 0.0
    private var settleDeadline: Double?
    private var stopping = false
    private var stopIssued = false
    private var finished = false
    private var failed = false
    private var exitCode: Int32 = 1
    private let completion = DispatchSemaphore(value: 0)
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    public static func capabilities() -> [String: String] {
        DispatchQueue(label: "mini-sandbox.vm-capability").sync {
            ["virtualizationSupported": String(VZVirtualMachine.isSupported),
             "minimumCPUCount": String(VZVirtualMachineConfiguration.minimumAllowedCPUCount),
             "maximumCPUCount": String(VZVirtualMachineConfiguration.maximumAllowedCPUCount),
             "minimumMemoryBytes": String(VZVirtualMachineConfiguration.minimumAllowedMemorySize),
             "maximumMemoryBytes": String(VZVirtualMachineConfiguration.maximumAllowedMemorySize),
             "vmBoot": "NOT_RUN", "configurationValidation": "NOT_RUN", "keychain": "NOT_QUERIED"]
        }
    }
    package func claimRun() -> Bool {
        runLock.lock(); defer { runLock.unlock() }
        guard !runClaimed else { return false }
        runClaimed = true
        return true
    }
    public func run(bundle: VMVerifiedBundle, sink: any SynchronousAuditSink) -> Int32 {
        guard claimRun() else { print("FAIL probe is one-shot"); return 1 }
        queue.async { self.start(bundle: bundle, sink: sink) }
        guard completion.wait(timeout: .now() + 72) == .success else {
            // A wedged framework/audit callback cannot make this diagnostic wait forever.
            print("FAIL hard deadline; actual stopped state UNKNOWN")
            return 1
        }
        return queue.sync { exitCode }
    }
    private func start(bundle: VMVerifiedBundle, sink: any SynchronousAuditSink) {
        dispatchPrecondition(condition: .onQueue(queue))
        runDeadline = now + 60
        let runID = UUID()
        do {
            guard VZVirtualMachine.isSupported else { exitCode = 2; finish(); return }
            let c = VZVirtualMachineConfiguration()
            c.platform = VZGenericPlatformConfiguration()
            let boot = VZLinuxBootLoader(kernelURL: bundle.kernel)
            boot.initialRamdiskURL = bundle.initramfs
            boot.commandLine = "console=hvc0 rdinit=/init minisandbox.run_id=\(runID.uuidString) minisandbox.epoch=1"
            c.bootLoader = boot
            guard (VZVirtualMachineConfiguration.minimumAllowedCPUCount...VZVirtualMachineConfiguration.maximumAllowedCPUCount).contains(2),
                  (VZVirtualMachineConfiguration.minimumAllowedMemorySize...VZVirtualMachineConfiguration.maximumAllowedMemorySize).contains(536870912) else { throw VMProtocolError.budget }
            c.cpuCount = 2; c.memorySize = 536870912
            c.networkDevices = []; c.directorySharingDevices = []; c.storageDevices = []
            c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
            let pipe = Pipe(); console = pipe
            let fd = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw VMProtocolError.truncated }
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: pipe.fileHandleForWriting)
            c.serialPorts = [serial]
            try c.validate()
            let machine = VZVirtualMachine(configuration: c, queue: queue); vm = machine; machine.delegate = self
            guard let socket = machine.socketDevices.first as? VZVirtioSocketDevice else { throw VMProtocolError.crossContext }
            device = socket
            let context = try VMDiagnosticSession(owner: socket, runID: runID, epoch: 1, workloadDigest: bundle.workloadDigest, sink: sink); session = context
            try context.event("vm.configuration", reason: "validated Linux generic; CPU=2 RAM=536870912 NIC=0 shares=0 disks=0 vsock=1 serial=bounded")
            let l = VZVirtioSocketListener(); l.delegate = self; listener = l; socket.setSocketListener(l, forPort: 4050)
            let t = DispatchSource.makeTimerSource(queue: queue); timer = t
            t.schedule(deadline: .now(), repeating: .milliseconds(10)); t.setEventHandler { [weak self] in self?.tick() }; t.resume()
            for number in [SIGINT, SIGTERM] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { [weak self] in self?.stop(failure: true, reason: "cancelled") }; source.resume(); signals.append(source)
            }
            try context.event("vm.start", reason: "framework start requested")
            lifetime.startPending = true
            machine.start { result in
                self.lifetime.startPending = false
                switch result {
                case .success:
                    do { try context.event("vm.start.callback", reason: "framework running; Linux boot not inferred") } catch { self.stop(failure: true, reason: "auditFailed") }
                case .failure:
                    do { try context.event("vm.start.callback", reason: "framework start failed", outcome: .failed) } catch { self.failed = true }
                    self.stop(failure: true, reason: "startFailed")
                }
                if self.stopping { self.progressStop() }
            }
        } catch {
            if session == nil {
                // No socket was installed: retain a revoked audit-only context for cleanup evidence.
                if let context = try? VMDiagnosticSession(owner: self, runID: runID, epoch: 1, workloadDigest: bundle.workloadDigest, sink: sink) {
                    context.revoke(); session = context
                    try? context.event("vm.preparation.failed", reason: "configuration or framework preparation failed", outcome: .failed)
                }
            }
            print("FAIL preparation: \(error)")
            stop(failure: true, reason: "preparationFailed")
        }
    }
    public func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection new: VZVirtioSocketConnection, from socket: VZVirtioSocketDevice) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let session else { new.close(); return false }
        if stopping || self.listener !== listener || device !== socket {
            do { try session.reject(stopping ? .stopped : .crossContext) }
            catch { stop(failure: true, reason: "auditFailed") }
            new.close(); return false
        }
        var opened = false
        do {
            try session.open(owner: socket, now: now)
            opened = true
            let fd = new.fileDescriptor
            var one: Int32 = 1
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw VMProtocolError.truncated }
            connection = new; parser = VMFrameParser(); output = Data(); connectionDeadline = now + 5
            return true
        } catch {
            new.close()
            if opened {
                session.close()
                do { try session.reject(.truncated) } catch { stop(failure: true, reason: "auditFailed") }
            }
            if session.revoked { stop(failure: true, reason: "sessionRevoked") }
            return false
        }
    }
    private func tick() {
        if finished { return }
        if stopping { progressStop(); return }
        if now >= runDeadline { stop(failure: true, reason: "runDeadline"); return }
        do {
            if let console {
                var bytes = [UInt8](repeating: 0, count: 240)
                let n = Darwin.read(console.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if n > 0 { try session?.guestDiagnostic(Data(bytes.prefix(n))) }
            }
            if let connection, let device, let session {
                if now >= connectionDeadline { try session.reject(.timeout); closeConnection() }
                else if !output.isEmpty {
                    let n = output.withUnsafeBytes { Darwin.write(connection.fileDescriptor, $0.baseAddress, $0.count) }
                    if n > 0 {
                        output.removeFirst(n)
                        if output.isEmpty { try session.replyWritten(); closeConnection() }
                    } else if n < 0 && errno != EAGAIN && errno != EINTR { try session.reject(.truncated); closeConnection() }
                } else {
                    // Read only header first. Oversized lengths are rejected before reading any body.
                    let count = parser.bufferedBytes < 4 ? 4 - parser.bufferedBytes : 38 - parser.bufferedBytes
                    var bytes = [UInt8](repeating: 0, count: count)
                    let n = Darwin.read(connection.fileDescriptor, &bytes, count)
                    if n > 0 {
                        let frame: VMFrame?
                        do { frame = try parser.feed(Data(bytes.prefix(n))) }
                        catch let error as VMProtocolError { try session.reject(error); closeConnection(); return }
                        if let frame {
                            do { output = try session.reply(to: frame, owner: device, now: now).encoded() }
                            catch { closeConnection(); if session.revoked { throw error } }
                        }
                    } else if n == 0 { try session.reject(.truncated); closeConnection() }
                    else if errno != EAGAIN && errno != EINTR { try session.reject(.truncated); closeConnection() }
                }
            }
            if let session, session.positiveReplies > 0, Set([VMProtocolError.type, .uuid, .oversized]).isSubset(of: session.rejections) {
                if settleDeadline == nil { settleDeadline = now + 0.5 }
                if now >= settleDeadline! { stop(failure: false, reason: "hostChecksComplete") }
            }
        } catch { stop(failure: true, reason: "auditOrIOFailed") }
    }
    private func closeConnection() { connection?.close(); connection = nil; output = Data(); session?.close() }
    private func stop(failure: Bool, reason: String) {
        failed = failed || failure
        guard !stopping else { return }
        stopping = true; stopDeadline = now + 10
        // Revocation and transport removal precede every destructive stop attempt.
        session?.revoke(); device?.removeSocketListener(forPort: 4050); listener = nil; closeConnection()
        // VZ's asynchronous start still reads the serial attachment's FileHandles.
        // Keep both ends valid through callback settlement AND actual stopped state.
        do { try session?.event("vm.stopping", reason: reason) } catch { failed = true }
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue); timer = t
            t.schedule(deadline: .now(), repeating: .milliseconds(10)); t.setEventHandler { [weak self] in self?.progressStop() }; t.resume()
        }
        progressStop()
    }
    private func progressStop() {
        guard !finished else { return }
        // Bounded nonblocking discard prevents a full console pipe blocking teardown.
        if let console {
            var bytes = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.read(console.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
        }
        guard let vm else { releaseConsole(); exitCode = 1; finish(); return }
        if lifetime.canReleaseResources(actualStopped: vm.state == .stopped) {
            do { try session?.event("vm.stopped", reason: "actual VZ state stopped", outcome: .completed) } catch { failed = true }
            releaseConsole()
            exitCode = failed ? 1 : 0; print(exitCode == 0 ? "PASS actual vsock positive, 3 host rejection cases, actual stopped" : "FAIL; actual VM stopped")
            finish(); return
        }
        if now >= stopDeadline {
            print("FAIL stop deadline; clean stopped UNKNOWN; actual state=\(vm.state.rawValue) startPending=\(lifetime.startPending) stopPending=\(lifetime.stopPending)")
            // Do not invalidate handles potentially still owned by framework work.
            exitCode = 1; finish(); return
        }
        if !lifetime.startPending && !stopIssued && vm.canStop {
            stopIssued = true
            lifetime.stopPending = true
            vm.stop { error in
                self.lifetime.stopPending = false
                if error != nil { self.failed = true }
                do { try self.session?.event("vm.stop.callback", reason: error == nil ? "framework stop completed" : "framework stop failed") } catch { self.failed = true }
                self.progressStop()
            }
        }
    }
    private func releaseConsole() {
        try? console?.fileHandleForReading.close(); try? console?.fileHandleForWriting.close(); console = nil
        do { try session?.event("vm.console.released", reason: "framework callbacks settled; console handles closed") } catch { failed = true }
    }
    private func finish() {
        guard !finished else { return }; finished = true
        timer?.cancel(); timer = nil
        for source in signals { source.cancel() }; signals = []
        completion.signal()
    }
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) { stop(failure: !stopping, reason: "guestStopped") }
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { stop(failure: true, reason: "frameworkError") }
}
