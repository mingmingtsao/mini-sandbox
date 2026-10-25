import Foundation
import Darwin
import SandboxContracts
@preconcurrency import Virtualization

package enum BusinessVMService: UInt32, CaseIterable, Sendable {
    case control = 4060, workspace = 4062, model = 4064, permission = 4065, mcp = 4066
}

package enum BusinessVMError: Error, Equatable, Sendable {
    case invalidResource, invalidProfile, invalidOwner, closed, timeout, capacity, io, alreadyClaimed
}

/// Minted only by the actual VM listener. Packet data never selects its run or
/// service. The VZ original is retired on the machine queue; a native consumer
/// may take one independently owned duplicate and must retire this owner when
/// its terminal cleanup runs, so the peer observes EOF and capacity is returned.
package final class BusinessVMConnection: @unchecked Sendable {
    package let id = UUID()
    package let runtimeID: UUID
    package let service: BusinessVMService
    package let lifecycle: RunLifecycle
    package let runID: UUID
    package let epoch: UInt64
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var original: VZVirtioSocketConnection?
    private var descriptor: Int32
    private var claimed = false
    private var frameClaimed = false
    private var closed = false
    private var readPending = false
    private var received = 0
    private var outboundBytes = 0
    private var outboundFrames = 0
    private let byteLimit: Int
    private let deadline: ContinuousClock.Instant
    private let retired: @Sendable (UUID) -> Void

    fileprivate init(connection: VZVirtioSocketConnection, session: BusinessVMSession,
                     service: BusinessVMService, queue: DispatchQueue,
                     retired: @escaping @Sendable (UUID) -> Void) throws {
        self.runtimeID = session.id; self.service = service
        lifecycle = session.handle.lifecycle; runID = session.grant.runID; epoch = session.grant.epoch
        self.queue = queue; original = connection; descriptor = connection.fileDescriptor
        self.retired = retired
        byteLimit = service == .workspace ? 32 * 1024 * 1024 : service == .control ? 2 * 1024 * 1024 : 81_920
        deadline = .now.advanced(by: .seconds(service == .workspace || service == .control ? 900 : 300))
        var type: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size), yes: Int32 = 1
        let flags = fcntl(descriptor, F_GETFL)
        guard descriptor >= 0, flags >= 0,
              getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &length) == 0, type == SOCK_STREAM,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw BusinessVMError.io }
    }

    /// One caller may read one bounded fragment at a time. No blocking read or
    /// framework call happens on the main thread. Zero bytes alone means EOF;
    /// EAGAIN/EINTR retry without fabricating an EOF or consuming more capacity.
    package func receive(maxBytes: Int = 4096) async throws -> Data {
        guard (1...16_384).contains(maxBytes) else { throw BusinessVMError.capacity }
        try lock.withLock {
            guard !closed, !claimed, !readPending else { throw BusinessVMError.closed }
            readPending = true
        }
        defer { lock.withLock { readPending = false } }
        while true {
            try Task.checkCancellation()
            let result: Data? = try lock.withLock {
                guard !closed, !claimed, descriptor >= 0 else { throw BusinessVMError.closed }
                guard ContinuousClock.now < deadline else { throw BusinessVMError.timeout }
                guard received < byteLimit else { throw BusinessVMError.capacity }
                var bytes = [UInt8](repeating: 0, count: min(maxBytes, byteLimit - received))
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count == 0 { return Data() }
                if count < 0 {
                    if errno == EAGAIN || errno == EINTR { return nil }
                    throw BusinessVMError.io
                }
                received += count
                return Data(bytes.prefix(count))
            }
            if let result { return result }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Exclusive one-use handoff. There is no public arbitrary-fd constructor.
    /// A failed setup in the consumer still owns and closes the returned fd.
    package func takeDescriptor() throws -> Int32 {
        try lock.withLock {
            guard !closed, !claimed, !frameClaimed, !readPending, descriptor >= 0,
                  service == .model || service == .mcp else { throw BusinessVMError.alreadyClaimed }
            guard ContinuousClock.now < deadline else { throw BusinessVMError.timeout }
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw BusinessVMError.io }
            claimed = true
            return duplicate
        }
    }

    func takeFrameDescriptor(bytes: Int) throws -> Int32 {
        try lock.withLock {
            let byteCap = service == .workspace ? 32 * 1024 * 1024 : service == .control ? 16_388 : 16_384
            let frameCap = service == .workspace ? 8192 : 1
            guard !closed, !claimed, !frameClaimed, descriptor >= 0,
                  [.control, .workspace, .permission].contains(service),
                  bytes > 0, bytes <= byteCap - outboundBytes, outboundFrames < frameCap,
                  ContinuousClock.now < deadline else { throw BusinessVMError.alreadyClaimed }
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw BusinessVMError.io }
            outboundBytes += bytes; outboundFrames += 1
            frameClaimed = true
            return duplicate
        }
    }
    func finishFrame(retire: Bool) {
        lock.withLock { frameClaimed = false }
        if retire { self.retire() }
    }
    func acquireFrameEffect() -> Bool { lock.try() }
    func validateFrameEffectLocked() throws {
        guard !closed, frameClaimed, descriptor >= 0, ContinuousClock.now < deadline else { throw BusinessVMError.closed }
    }
    func releaseFrameEffect() { lock.unlock() }
    package func acquireNativeEffect() -> Bool { lock.try() }
    // Concrete prepared transports take this after their operation lock and
    // before the shared lifecycle clock fence. No lifecycle lock may be held
    // while waiting here; startLocked then validates with this ownership held.
    func acquireNativeStart() { lock.lock() }
    package func validateNativeEffectLocked() throws {
        guard !closed, claimed, descriptor >= 0, ContinuousClock.now < deadline else { throw BusinessVMError.closed }
    }
    package func releaseNativeEffect() { lock.unlock() }

    package var isRetired: Bool { lock.withLock { closed } }
    package func retire() {
        let changed = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true; descriptor = -1
            return true
        }
        guard changed else { return }
        queue.async { [self] in
            original?.close(); original = nil
            retired(id)
        }
    }

    deinit {
        // Normal owners are retained by the session until retirement on its VM
        // queue. An unexposed setup failure is also constructed on that queue.
        original?.close()
    }
}

// Keep the only constructor and authenticated acceptance in the same source file.
extension BusinessVMSession {
    func accepted(_ connection: VZVirtioSocketConnection, from device: VZVirtioSocketDevice,
                  listener: VZVirtioSocketListener) -> Bool {
        guard !closing, socketDevice === device,
              let service = listeners.first(where: { $0.value === listener })?.key,
              connections.count < 8,
              connections.values.filter({ $0.service == service }).count < (service == .model || service == .mcp ? min(2, grant.resourceLimits.concurrentRequests) : 1),
              admittedConnections[service, default: 0] < (service == .control || service == .workspace ? 1 : 64),
              handle.lifecycle.observeAndReduce(reason: "business-vm-accept").status == .active,
              handle.lifecycle.currentGeneration == grant.epoch else {
            connection.close(); return false
        }
        do {
            let owner = try BusinessVMConnection(connection: connection, session: self,
                service: service, queue: queue) { [weak self] id in self?.removeConnection(id) }
            connections[owner.id] = owner
            admittedConnections[service, default: 0] += 1
            guard publish(owner) else { owner.retire(); requestStop(); return false }
            return true
        } catch { connection.close(); return false }
    }
}
