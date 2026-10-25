import Darwin
import Foundation
import SandboxContracts
@preconcurrency import Virtualization

package struct BusinessVMStopReport: Sendable {
    package let runtimeID: UUID
    package let runID: UUID
    package let epoch: UInt64
    package let actualStopped: Bool
    package let callbacksSettled: Bool
    package let diskRemoved: Bool
    package let consoleBytes: Int
    package let startInvoked: Bool
    package let stoppedDuringStart: Bool
    fileprivate init(
        runtimeID: UUID, runID: UUID, epoch: UInt64, actualStopped: Bool,
        callbacksSettled: Bool, diskRemoved: Bool, consoleBytes: Int,
        startInvoked: Bool, stoppedDuringStart: Bool
    ) {
        self.runtimeID = runtimeID
        self.runID = runID
        self.epoch = epoch
        self.actualStopped = actualStopped
        self.callbacksSettled = callbacksSettled
        self.diskRemoved = diskRemoved
        self.consoleBytes = consoleBytes
        self.startInvoked = startInvoked
        self.stoppedDuringStart = stoppedDuringStart
    }
}

package enum BusinessVMEvent: String, Sendable { case preparing, starting, running, stopping, stopped, failed }

/// One fresh, installed run owns one actual VZ machine. No network device or
/// writable host directory is attached. Framework operations stay on its queue;
/// cancellation latches before queueing teardown and callback results are never
/// published after closing. A report distinguishes actual stop from timeout.
package final class BusinessVMSession: NSObject, VZVirtioSocketListenerDelegate,
    VZVirtualMachineDelegate, @unchecked Sendable
{
    package let id = UUID()
    package let handle: HostRunHandle
    package let grant: RunGrant
    package let incoming: AsyncStream<BusinessVMConnection>
    let incomingContinuation: AsyncStream<BusinessVMConnection>.Continuation
    package let events: AsyncStream<BusinessVMEvent>
    private let eventContinuation: AsyncStream<BusinessVMEvent>.Continuation
    let queue = DispatchQueue(label: "mini-sandbox.business-vm")
    let bundle: BusinessRuntimeBundle
    private let sessionDirectory: URL
    private let stopLock = NSLock()
    private var stopRequested = false
    private var liveOwners: [UUID: BusinessVMConnection] = [:]
    var closing: Bool { stopLock.withLock { stopRequested } }
    var socketDevice: VZVirtioSocketDevice?
    var listeners: [BusinessVMService: VZVirtioSocketListener] = [:]
    var connections: [UUID: BusinessVMConnection] = [:]
    var admittedConnections: [BusinessVMService: Int] = [:]
    private var machine: VZVirtualMachine?
    private var console: Pipe?
    private var consoleBytes = 0
    private var disk: URL?
    private var timer: DispatchSourceTimer?
    private var startPending = false, stopPending = false, stopIssued = false
    private var stoppedDuringStart = false
    private var prepared: BusinessVMPreparedStart?
    private let effectID = UUID()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopWaiters: [CheckedContinuation<BusinessVMStopReport, Never>] = []
    private var stopReport: BusinessVMStopReport?
    private var stopDeadline: ContinuousClock.Instant?
    private var lifetimeDeadline: ContinuousClock.Instant?
    private var retention: BusinessVMSession?

    package init(
        authority: RunAuthorizationController, handle: HostRunHandle, grant: RunGrant,
        bundle: BusinessRuntimeBundle, sessionDirectory: URL
    ) throws {
        guard try authority.installedGrantForOwnership(of: handle) == grant,
            handle.lifecycle.observeAndReduce(reason: "business-vm-install").status == .active,
            handle.lifecycle.currentGeneration == grant.epoch,
            grant.workloadImageDigest == bundle.imageSHA256,
            grant.agentAdapterVersion == BusinessRuntimeBundle.profile,
            grant.resourceLimits.cpuCount >= 2, grant.resourceLimits.memoryBytes >= 1_073_741_824,
            grant.resourceLimits.diskBytes >= 67_108_864, grant.resourceLimits.messageBytes >= 16_384
        else { throw BusinessVMError.invalidOwner }
        try BusinessRuntimeBundle.checkDirectory(sessionDirectory)
        self.handle = handle
        self.grant = grant
        self.bundle = bundle
        self.sessionDirectory = sessionDirectory
        let input = AsyncStream<BusinessVMConnection>.makeStream(bufferingPolicy: .bufferingOldest(8))
        incoming = input.stream
        incomingContinuation = input.continuation
        let status = AsyncStream<BusinessVMEvent>.makeStream(bufferingPolicy: .bufferingOldest(16))
        events = status.stream
        eventContinuation = status.continuation
        super.init()
    }

    package func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard machine == nil, startContinuation == nil, stopReport == nil, !closing else {
                    continuation.resume(throwing: BusinessVMError.closed)
                    return
                }
                startContinuation = continuation
                retention = self
                eventContinuation.yield(.preparing)
                do { try prepareAndStart() } catch {
                    startContinuation?.resume(throwing: error)
                    startContinuation = nil
                    eventContinuation.yield(.failed)
                    requestStop()
                }
            }
        }
    }

    private func prepareAndStart() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closing else { throw BusinessVMError.closed }
        let diskURL = sessionDirectory.appendingPathComponent("private.raw")
        let fd = open(diskURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BusinessVMError.invalidResource }
        disk = diskURL
        let sized = ftruncate(fd, 67_108_864)
        Darwin.close(fd)
        guard sized == 0 else { throw BusinessVMError.io }
        let config = VZVirtualMachineConfiguration()
        config.platform = VZGenericPlatformConfiguration()
        let boot = VZLinuxBootLoader(kernelURL: bundle.kernel)
        boot.initialRamdiskURL = bundle.initramfs
        boot.commandLine = "console=hvc0 rdinit=/init"
        config.bootLoader = boot
        config.cpuCount = 2
        config.memorySize = 1_073_741_824
        config.networkDevices = []
        config.directorySharingDevices = []
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(
                    url: diskURL, readOnly: false, cachingMode: .uncached, synchronizationMode: .full)),
            VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(
                    url: bundle.vendorDisk, readOnly: true, cachingMode: .uncached, synchronizationMode: .full)),
        ]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let pipe = Pipe()
        console = pipe
        guard fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) >= 0 else {
            throw BusinessVMError.io
        }
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil, fileHandleForWriting: pipe.fileHandleForWriting)
        config.serialPorts = [serial]
        try config.validate()
        let vm = VZVirtualMachine(configuration: config, queue: queue)
        machine = vm
        vm.delegate = self
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else { throw BusinessVMError.invalidOwner }
        socketDevice = device
        for service in BusinessVMService.allCases {
            let listener = VZVirtioSocketListener()
            listener.delegate = self
            listeners[service] = listener
            device.setSocketListener(listener, forPort: service.rawValue)
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        timer = source
        source.schedule(deadline: .now(), repeating: .milliseconds(10))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        lifetimeDeadline = .now.advanced(by: .seconds(900))
        let operation = BusinessVMPreparedStart(machine: vm, session: self)
        prepared = operation
        let scope = try handle.lifecycle.runScope(for: handle, epoch: grant.epoch)
        startPending = true
        eventContinuation.yield(.starting)
        do {
            try handle.lifecycle.start(
                .businessVM(operation), id: effectID, scope: scope,
                notBefore: grant.createdAt, startDeadline: grant.expiresAt)
        } catch {
            startPending = false
            throw error
        }
    }

    func didStart(_ result: Result<Void, Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        startPending = false
        switch result {
        case .success:
            if !closing, handle.lifecycle.observeAndReduce(reason: "business-vm-start-return").status == .active,
                handle.lifecycle.currentGeneration == grant.epoch
            {
                eventContinuation.yield(.running)
                startContinuation?.resume()
            } else {
                startContinuation?.resume(throwing: BusinessVMError.closed)
                requestStop()
            }
        case .failure:
            eventContinuation.yield(.failed)
            startContinuation?.resume(throwing: BusinessVMError.io)
            requestStop()
        }
        startContinuation = nil
        if closing { progressStop() }
    }

    package func cancel() {
        handle.lifecycle.terminate(.stopped)
        requestStop()
    }

    /// Physical stop after a complete frozen result. It does not reactivate a
    /// stopped grant. The coordinator must adopt only after this report confirms
    /// stopped state and callbacks, and separately stop the run when appropriate.
    package func stopForResult() { requestStop() }

    func requestStop() {
        let owners = stopLock.withLock { () -> [BusinessVMConnection]? in
            guard !stopRequested else { return nil }
            stopRequested = true
            return Array(liveOwners.values)
        }
        guard let owners else { return }
        // Synchronously retire concrete channel ownership before waiting for the
        // VM queue. Their VZ originals are closed later on that queue.
        for owner in owners { owner.retire() }
        queue.async { [self] in
            stoppedDuringStart = startPending
            stopDeadline = .now.advanced(by: .seconds(15))
            eventContinuation.yield(.stopping)
            for service in BusinessVMService.allCases { socketDevice?.removeSocketListener(forPort: service.rawValue) }
            listeners.removeAll()
            for owner in connections.values { owner.retire() }
            incomingContinuation.finish()
            if timer == nil {
                let source = DispatchSource.makeTimerSource(queue: queue)
                timer = source
                source.schedule(deadline: .now(), repeating: .milliseconds(10))
                source.setEventHandler { [weak self] in self?.tick() }
                source.resume()
            }
            progressStop()
        }
    }

    func publish(_ owner: BusinessVMConnection) -> Bool {
        stopLock.withLock {
            guard !stopRequested else { return false }
            liveOwners[owner.id] = owner
            switch incomingContinuation.yield(owner) {
            case .enqueued: return true
            default: return false
            }
        }
    }
    func removeConnection(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        connections.removeValue(forKey: id)
        _ = stopLock.withLock { liveOwners.removeValue(forKey: id) }
    }

    package func waitUntilStopped() async -> BusinessVMStopReport {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let stopReport {
                    continuation.resume(returning: stopReport)
                } else if stopWaiters.count < 16 {
                    stopWaiters.append(continuation)
                } else {
                    continuation.resume(
                        returning: report(actualStopped: false, callbacksSettled: false, diskRemoved: false))
                }
            }
        }
    }

    private func tick() {
        if let pipe = console {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count > 0 { consoleBytes = min(Int.max - 4096, consoleBytes) + count }
        }
        if closing {
            progressStop()
            return
        }
        if let deadline = lifetimeDeadline, ContinuousClock.now >= deadline {
            cancel()
            return
        }
        if handle.lifecycle.observeAndReduce(reason: "business-vm-lifetime").status != .active { requestStop() }
    }

    private func progressStop() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard closing else { return }
        if machine == nil || machine?.state == .stopped, !startPending, !stopPending {
            for owner in connections.values { owner.retire() }
            // Retirement enqueues VZ.close on this queue. Yield once so every
            // original socket is actually closed before release/reporting.
            guard connections.isEmpty else { return }
            try? console?.fileHandleForReading.close()
            try? console?.fileHandleForWriting.close()
            console = nil
            machine = nil
            socketDevice = nil
            let removed: Bool
            if let disk {
                removed = unlink(disk.path) == 0
                self.disk = nil
            } else {
                removed = true
            }
            let report = report(actualStopped: true, callbacksSettled: true, diskRemoved: removed)
            finish(report)
            timer?.cancel()
            timer = nil
            handle.lifecycle.finishEffect(effectID)
            prepared = nil
            retention = nil
            return
        }
        if let deadline = stopDeadline, ContinuousClock.now >= deadline, stopReport == nil {
            // Keep framework attachments alive and continue servicing callbacks.
            // A timeout is not an actual stopped state or permission to unlink.
            finish(report(actualStopped: false, callbacksSettled: !startPending && !stopPending, diskRemoved: false))
        }
        if !startPending, !stopIssued, let machine, machine.canStop {
            stopIssued = true
            stopPending = true
            machine.stop { [self] _ in
                stopPending = false
                progressStop()
            }
        }
    }

    private func finish(_ report: BusinessVMStopReport) {
        if report.actualStopped { eventContinuation.yield(.stopped) } else { eventContinuation.yield(.failed) }
        stopReport = report
        startContinuation?.resume(throwing: BusinessVMError.closed)
        startContinuation = nil
        for waiter in stopWaiters { waiter.resume(returning: report) }
        stopWaiters.removeAll()
        if report.actualStopped { eventContinuation.finish() }
    }

    private func report(actualStopped: Bool, callbacksSettled: Bool, diskRemoved: Bool) -> BusinessVMStopReport {
        BusinessVMStopReport(
            runtimeID: id, runID: grant.runID, epoch: grant.epoch, actualStopped: actualStopped,
            callbacksSettled: callbacksSettled, diskRemoved: diskRemoved, consoleBytes: consoleBytes,
            startInvoked: prepared?.didInvokeStart ?? false, stoppedDuringStart: stoppedDuringStart)
    }

    #if DEBUG || SANDBOX_TEST_FIXTURES
        /// A bounded fault-injection point for actual VZ backpressure checks. This
        /// method is absent from the normal optimized application. It does not emit
        /// output or change authorization; cancellation still owns the paused VM.
        package func pauseForBackpressureCheck() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !closing, let machine, machine.canPause else {
                        continuation.resume(throwing: BusinessVMError.closed)
                        return
                    }
                    machine.pause { result in
                        guard !self.closing else {
                            continuation.resume(throwing: BusinessVMError.closed)
                            return
                        }
                        continuation.resume(with: result)
                    }
                }
            }
        }
    #endif

    package func makeFrameOutput(connection: BusinessVMConnection, body: Data) throws -> BusinessVMFrameOutput {
        guard connection.runtimeID == id, [.control, .workspace].contains(connection.service) else {
            throw BusinessVMError.invalidOwner
        }
        let scope = try handle.lifecycle.runScope(for: handle, epoch: grant.epoch)
        return try BusinessVMFrameOutput(connection: connection, handle: handle, scope: scope, body: body)
    }
    package func listener(
        _ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        accepted(connection, from: socketDevice, listener: listener)
    }
    package func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        if !closing { handle.lifecycle.terminate(.faulted) }
        requestStop()
    }
    package func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { cancel() }
}
