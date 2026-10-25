import Darwin
import Foundation

package enum NativeResponseError: Error, Equatable {
    case invalidSocket, invalidEvent, limitExceeded, disconnected
}

/// A single host-adopted local stream socket. No descriptor, route or callback is
/// exported. ControlledRunOutput's lock owns all mutable state; send is invoked
/// only by its acceptOne, while the existing RunLifecycle fence is held.
final class NativeResponseChannel {
    static let maxFrameBytes = 1_048_576
    static let maxPendingBytes = 2_097_152
    static let maxResponseBytes = 8_388_608
    static let maxPendingEvents = 256
    static let maxWriteBytes = 16_384
    struct Frame {
        let bytes: Data
        let final: Bool
    }
    struct Cleanup {
        var descriptor: Int32 = -1
        var frames: [Frame] = []
        var serializer: NativeResponseSerializer?
        var vmOwner: BusinessVMConnection?
        func dispose() {
            if descriptor >= 0 { Darwin.close(descriptor) }
            vmOwner?.retire()
        }
    }
    private var cleanup = Cleanup()
    func takeCleanup() -> Cleanup {
        let result = cleanup
        cleanup = Cleanup()
        return result
    }
    private var descriptor: Int32
    private let vmOwner: BusinessVMConnection?
    private var frames: [Frame] = []
    private var offset = 0
    private var serializer: NativeResponseSerializer
    private var totalBytes = 0
    private(set) var largestFrameBytes = 0
    private(set) var peakQueuedEvents = 0
    private(set) var peakBufferedBytes = 0
    var cumulativeEnqueuedBytes: Int { totalBytes }
    private(set) var pendingBytes = 0
    private(set) var committedBytes = 0
    private(set) var writeCalls = 0
    private(set) var acceptedEvents = 0
    private(set) var acceptedFinals = 0
    private(set) var wouldBlockCount = 0
    private(set) var partialWriteCount = 0
    var queuedEvents: Int { frames.count }
    var bufferedBytes: Int { frames.reduce(0) { $0 + $1.bytes.count } }
    var isClosed: Bool { descriptor < 0 }
    var isMCP: Bool { serializer.mcp }
    func matchesVMConnection(_ connection: BusinessVMConnection) -> Bool { vmOwner === connection }

    /// Takes exclusive ownership immediately, including on setup failure. The
    /// trusted host must relinquish its fd; this accepts connected AF_UNIX stream
    /// sockets only. VM/device descriptor binding requires separate acceptance.
    init(takingAcceptedSocket fd: Int32, streaming: Bool, mcp: Bool = false) throws {
        descriptor = fd
        serializer = NativeResponseSerializer(streaming: streaming, mcp: mcp)
        vmOwner = nil
        var type: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        var peer = sockaddr_un()
        var peerLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &peerLength) }
        }
        var yes: Int32 = 1
        let flags = fcntl(fd, F_GETFL)
        guard fd >= 0, connected == 0, Int32(peer.sun_family) == AF_UNIX,
            getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) == 0, type == SOCK_STREAM,
            flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
            fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            close()
            throw NativeResponseError.invalidSocket
        }
    }
    /// The alternate constructor takes a concrete connection minted by the
    /// installed VZ listener, never a caller-selected arbitrary descriptor.
    /// The framework original and this one duplicate share a single retirement
    /// owner; neither can be reused by another output or later request.
    init(takingVMConnection owner: BusinessVMConnection, streaming: Bool, mcp: Bool = false) throws {
        descriptor = -1
        serializer = NativeResponseSerializer(streaming: streaming, mcp: mcp)
        vmOwner = owner
        do {
            guard owner.service == (mcp ? .mcp : .model) else { throw NativeResponseError.invalidSocket }
            descriptor = try owner.takeDescriptor()
            var type: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            var yes: Int32 = 1
            let flags = fcntl(descriptor, F_GETFL)
            guard descriptor >= 0, flags >= 0,
                getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &length) == 0, type == SOCK_STREAM,
                fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0
            else {
                throw NativeResponseError.invalidSocket
            }
        } catch {
            close()
            throw error
        }
    }
    deinit {
        cleanup.dispose()
        close()
    }
    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        vmOwner?.retire()
    }
    func acquireOwnerForAcceptance() -> Bool { vmOwner?.acquireNativeEffect() ?? true }
    func releaseOwnerForAcceptance() { vmOwner?.releaseNativeEffect() }
    func detachTerminal() {
        cleanup.frames += frames
        cleanup.serializer = serializer
        frames.removeAll()
        pendingBytes = 0
        offset = 0
        serializer = NativeResponseSerializer(streaming: serializer.streaming, mcp: serializer.mcp)
        if descriptor >= 0 {
            cleanup.descriptor = descriptor
            descriptor = -1
        }
        cleanup.vmOwner = vmOwner
    }
    func enqueue(_ event: ControlledRunOutput.Event) throws {
        guard !isClosed else { throw NativeResponseError.disconnected }
        guard frames.count < Self.maxPendingEvents else { throw NativeResponseError.limitExceeded }
        // Copy-on-success: failed encoding/capacity checks do not consume protocol state.
        var next = serializer
        let budget = min(Self.maxFrameBytes, Self.maxPendingBytes - bufferedBytes, Self.maxResponseBytes - totalBytes)
        let frame = try next.encode(event, maxBytes: budget)
        // A partially sent Data still retains its whole allocation. Do not grant
        // new queue capacity until that complete frame has been released.
        guard frame.bytes.count <= Self.maxPendingBytes - bufferedBytes,
            frame.bytes.count <= Self.maxResponseBytes - totalBytes
        else { throw NativeResponseError.limitExceeded }
        serializer = next
        frames.append(frame)
        pendingBytes += frame.bytes.count
        totalBytes += frame.bytes.count
        largestFrameBytes = max(largestFrameBytes, frame.bytes.count)
        peakQueuedEvents = max(peakQueuedEvents, frames.count)
        peakBufferedBytes = max(peakBufferedBytes, bufferedBytes)
    }
    /// One real nonblocking syscall, never an async write or unchecked retry.
    /// True means bytes committed now, not a whole message or peer consumption.
    func acceptOne() throws -> Bool {
        try vmOwner?.validateNativeEffectLocked()
        guard let frame = frames.first else { return false }
        guard descriptor >= 0 else { throw NativeResponseError.disconnected }
        let count = min(Self.maxWriteBytes, frame.bytes.count - offset)
        writeCalls += 1
        let n = frame.bytes.withUnsafeBytes { bytes in
            Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), count, 0)
        }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                wouldBlockCount += 1
                return false
            }
            if errno == EINTR { return false }  // next attempt must re-enter lifecycle
            detachTerminal()
            throw NativeResponseError.disconnected
        }
        guard n > 0 else {
            detachTerminal()
            throw NativeResponseError.disconnected
        }
        committedBytes += n
        pendingBytes -= n
        offset += n
        if n < count { partialWriteCount += 1 }
        if offset == frame.bytes.count {
            cleanup.frames.append(frame)
            frames.removeFirst()
            offset = 0
            acceptedEvents += 1
            if frame.final {
                acceptedFinals += 1
                detachTerminal()
            }
        }
        return true
    }
}
