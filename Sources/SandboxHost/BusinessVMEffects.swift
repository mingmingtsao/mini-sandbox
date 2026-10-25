import Foundation
import Darwin
@preconcurrency import Virtualization

/// Prepared and invoked on the VM queue. The lifecycle takes this concrete
/// owner's lock before its own clock fence and calls startLocked directly.
final class BusinessVMPreparedStart: @unchecked Sendable {
    let handle: HostRunHandle
    let generation: UInt64
    private let lock = NSLock()
    private let machine: VZVirtualMachine
    private let queue: DispatchQueue
    private weak var session: BusinessVMSession?
    private var cancelled = false
    private var started = false
    init(machine: VZVirtualMachine, session: BusinessVMSession) {
        handle = session.handle; generation = session.grant.epoch
        self.machine = machine; self.session = session; queue = session.queue
    }
    func acquireForStart() { lock.lock() }
    func releaseForStart() { lock.unlock() }
    func startLocked() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !cancelled, !started else { throw BusinessVMError.closed }
        started = true
        machine.start { [weak session] result in session?.didStart(result) }
    }
    func cancel() {
        lock.withLock { cancelled = true }
        session?.requestStop()
    }
}

/// One immutable, bounded, concrete frame write. It cannot start a process,
/// mutate caller state, route a URL, run a closure, or grant a future permit.
package final class BusinessVMFrameOutput: @unchecked Sendable {
    let handle: HostRunHandle
    let generation: UInt64
    let scope: RunEffectScope
    let lifecycle: RunLifecycle
    let channelID: UUID
    let actionID: UUID?
    private let lock = NSLock()
    private let connection: BusinessVMConnection
    private let bytes: Data
    private var descriptor: Int32
    private var offset = 0
    private var terminal = false
    private var cleanupDescriptor: Int32 = -1
    private var cleanupOwner = false
    private let retireAfterFrame: Bool
    private var writeCount = 0

    init(connection: BusinessVMConnection, handle: HostRunHandle, scope: RunEffectScope,
         body: Data, actionID: UUID? = nil) throws {
        guard connection.lifecycle === handle.lifecycle, connection.runID == handle.runID,
              connection.epoch == scope.generation, !body.isEmpty, body.count <= 16_384,
              [.control, .workspace, .permission].contains(connection.service) else { throw BusinessVMError.invalidOwner }
        if connection.service == .permission {
            guard actionID != nil, scope.connectionID != nil else { throw BusinessVMError.invalidOwner }
            self.bytes = body; retireAfterFrame = true
        } else {
            guard actionID == nil else { throw BusinessVMError.invalidOwner }
            var length = UInt32(body.count).bigEndian
            self.bytes = withUnsafeBytes(of: &length) { Data($0) } + body
            retireAfterFrame = false
        }
        self.handle = handle; generation = scope.generation; self.scope = scope
        lifecycle = handle.lifecycle; channelID = connection.id; self.actionID = actionID
        self.connection = connection
        descriptor = try connection.takeFrameDescriptor()
    }

    package var completed: Bool { lock.withLock { terminal && offset == bytes.count } }
    package var committedBytes: Int { lock.withLock { offset } }
    package var writeCalls: Int { lock.withLock { writeCount } }
    package func acceptNext() throws -> Bool {
        do { return try lifecycle.acceptVMFrame(self) }
        catch { cancel(); throw error }
    }
    func acquireForAcceptance() -> Bool {
        guard lock.try() else { return false }
        guard connection.acquireFrameEffect() else { lock.unlock(); return false }
        return true
    }
    func prepareAcceptanceLocked() throws {
        guard !terminal, descriptor >= 0 else { throw BusinessVMError.closed }
        try connection.validateFrameEffectLocked()
    }
    func acceptLocked() throws -> Bool {
        guard !terminal, descriptor >= 0 else { throw BusinessVMError.closed }
        // Connection ownership is already held; this final deadline sample is
        // after the lifecycle lock wait and does not acquire another app lock.
        try connection.validateFrameEffectLocked()
        let written = bytes.withUnsafeBytes {
            Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), min(16_384, bytes.count - offset), 0)
        }
        writeCount += 1
        if written < 0 {
            if errno == EAGAIN || errno == EINTR { return false }
            throw BusinessVMError.io
        }
        guard written > 0 else { throw BusinessVMError.io }
        offset += written
        if offset == bytes.count { detachLocked() }
        return true
    }
    private func detachLocked() {
        guard !terminal else { return }
        terminal = true; cleanupDescriptor = descriptor; descriptor = -1; cleanupOwner = true
    }
    func releaseForAcceptance() {
        let fd = cleanupDescriptor, finish = cleanupOwner
        cleanupDescriptor = -1; cleanupOwner = false
        connection.releaseFrameEffect()
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
        if finish { connection.finishFrame(retire: retireAfterFrame || offset != bytes.count) }
    }
    package func cancel() {
        lock.lock(); detachLocked()
        let fd = cleanupDescriptor, finish = cleanupOwner
        cleanupDescriptor = -1; cleanupOwner = false
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
        if finish { connection.finishFrame(retire: true) }
    }
    deinit { cancel() }
}
