import Foundation
import SandboxContracts
import SandboxHost
import SandboxWorkbench

@MainActor enum CompositionBusinessChecks {
    static func run() async throws {
        try frameBuffer()
        for succeeded in [true, false] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("business-close-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: url) }
            let composition = try RunComposition(
                audit: WorkbenchAuditSink(newFileAt: url), credentialStore: SettingsStore())
            let run = try await composition.install(ConnectionSettingsChecks.makeGrant(nil))
            let token = try composition.beginBusinessOwnership(run)
            let business = composition.business
            composition.beginClose()
            var completed = false
            let close = Task {
                let result = await composition.close()
                completed = true
                return result
            }
            for _ in 0..<100 { await Task.yield() }
            let held =
                !completed && !composition.isClosed && business.isClosing
                && run.authorityHandle.lifecycle.currentStatus != .active
            composition.finishBusinessOwnership(token, succeeded: succeeded)
            let first = await close.value
            let again = await composition.close()
            try CompositionDiagnosticChecks.require(
                held && first == succeeded && again == succeeded,
                "business attachment cleanup must hold native close and preserve failure")
            print("PASS composition business close waits cleanup succeeded=\(succeeded)")
        }
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("business-source-\(UUID()).jsonl")
        let receiverURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "business-receiver-\(UUID()).jsonl")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: receiverURL)
        }
        let source = try RunComposition(
            audit: WorkbenchAuditSink(newFileAt: sourceURL), credentialStore: SettingsStore())
        let receiver = try RunComposition(
            audit: WorkbenchAuditSink(newFileAt: receiverURL), credentialStore: SettingsStore())
        let grant = try ConnectionSettingsChecks.makeGrant(nil)
        let local = try await source.install(grant)
        _ = try await receiver.install(grant)
        var rejected = false
        do { _ = try receiver.beginBusinessOwnership(local) } catch AuthorizationError.invalidHandle { rejected = true }
        let receivingClosed = await receiver.close()
        let sourceActive = local.authorityHandle.lifecycle.currentStatus == .active
        let sourceClosed = await source.close()
        try CompositionDiagnosticChecks.require(
            rejected && receivingClosed && sourceActive && sourceClosed,
            "business intake must reject foreign equal-ID authority without retiring source")
        print("PASS composition business owner rejects foreign equal-ID run")
    }
    private static func frameBuffer() throws {
        func framed(_ data: Data) -> Data {
            var length = UInt32(data.count).bigEndian
            return withUnsafeBytes(of: &length) { Data($0) } + data
        }
        let expected = [Data("ready".utf8), Data(repeating: 65, count: 4096), Data("finished".utf8)]
        let wire = expected.reduce(Data()) { $0 + framed($1) }
        for fragment in [1, 3, 17, 4096] {
            var buffer = BusinessFrameBuffer()
            var received = [Data]()
            var cursor = 0
            while cursor < wire.count {
                let end = min(wire.count, cursor + fragment)
                try buffer.append(Data(wire[cursor..<end]))
                cursor = end
                while let next = try buffer.next() { received.append(next) }
            }
            try CompositionDiagnosticChecks.require(
                received == expected && buffer.isEmpty,
                "fragmented/coalesced VM frames retain exact bytes and safe indices")
        }
        for invalid: UInt32 in [0, 16385, UInt32.max] {
            var buffer = BusinessFrameBuffer()
            var length = invalid.bigEndian
            try buffer.append(withUnsafeBytes(of: &length) { Data($0) })
            do {
                _ = try buffer.next()
                throw CompositionDiagnosticChecks.Failure(message: "invalid VM frame length")
            } catch BusinessTaskFailure.invalidFrame {}
        }
        print("PASS App VM frame decoder fragmented/coalesced multi-frame indices and bounded lengths")
    }
}
