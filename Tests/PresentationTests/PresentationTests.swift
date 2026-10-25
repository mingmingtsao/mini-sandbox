import AppKit
import SwiftUI
import Vision
import SandboxHost
import SandboxContracts
@testable import SandboxWorkbench
@testable import MiniSandboxApp

struct PresentationFailure: Error { let message: String }
func expectPresentation(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw PresentationFailure(message: message) }
}

/// Owned off-screen windows render actual product views. OCR checks pixels,
/// including SwiftUI text not exposed by in-process accessibility getters.
@MainActor final class Surface {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    init<V: View>(_ view: V, width: CGFloat = 1100, height: CGFloat = 1500) {
        host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .light).background(Color.white)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.makeKeyAndOrderFront(nil)
    }
    func dispose() { window.orderOut(nil); window.contentView = nil; window.close() }
    func image(in view: NSView? = nil) throws -> CGImage {
        let view = view ?? host
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PresentationFailure(message: "no render buffer") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw PresentationFailure(message: "no rendered pixels") }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PresentationFailure(message: "no image compositor") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        context.draw(image, in: rect)
        guard let opaque = context.makeImage() else { throw PresentationFailure(message: "no opaque image") }
        return opaque
    }
    func text(in view: NSView? = nil) throws -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image(in: view)).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
    }
    func contains(_ needle: String, in view: NSView? = nil) throws -> Bool { try text(in: view).map(\.0).joined(separator: " ").contains(needle) }
    func click(_ label: String, in view: NSView? = nil) throws {
        let view = view ?? host
        func nativeButtons(_ parent: NSView) -> [NSButton] {
            (parent as? NSButton).map { [$0] } ?? parent.subviews.flatMap(nativeButtons)
        }
        if let button = nativeButtons(view).first(where: { $0.title == label }) {
            try expectPresentation(button.isEnabled, "control disabled: " + label)
            button.performClick(nil)
            return
        }
        guard let owner = view.window, let rect = try text(in: view).first(where: { $0.0 == label })?.1 else { throw PresentationFailure(message: "missing control: " + label) }
        let point = NSPoint(x: rect.midX * view.bounds.width, y: (view.isFlipped ? 1 - rect.midY : rect.midY) * view.bounds.height)
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { throw PresentationFailure(message: "missing click event") }
            NSApplication.shared.postEvent(event, atStart: false)
        }
        // Queue both events before dispatch so AppKit tracking can receive up.
        while let event = NSApplication.shared.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) { NSApplication.shared.sendEvent(event) }
    }
    func enterCredential(_ value: String) throws {
        try click("Enter replacement API key")
        guard let editor = window.firstResponder as? NSTextView else { throw PresentationFailure(message: "secure field did not receive focus") }
        editor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

final class PresentationStore: FixedModelCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func credential(for model: FixedModel) throws -> String {
        try lock.withLock { reads += 1; guard let value else { throw CredentialProviderError.missing }; return value }
    }
    func save(_ value: String) throws { lock.withLock { reads += 1; self.value = value } }
    func delete() throws { lock.withLock { reads += 1; value = nil } }
    func check() throws -> Bool { lock.withLock { reads += 1; return value != nil } }
}

@main enum PresentationChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        Task { @MainActor in
            do { try await run(); print("PASS all presentation checks"); fflush(stdout); exit(0) }
            catch { print("FAIL presentation: \(error)"); fflush(stdout); exit(1) }
        }
        app.run()
        print("FAIL presentation: event loop returned before checks completed")
        exit(1)
    }
    @MainActor static func run() async throws {
        let model = WorkbenchModel(unavailable: "Synthetic authority failure")
        let surface = Surface(WorkbenchView(model: model))
        defer { surface.dispose() }
        try await Task.sleep(for: .milliseconds(100))
        try expectPresentation(try surface.contains("Synthetic authority failure"), "rendered error does not match authority state")
        try expectPresentation(!model.authorityAvailable && model.pending.isEmpty, "unavailable state admitted actions")
        print("PASS unavailable workbench pixels expose authority failure and no pending actions")
        try await workbench()
        try await environment()
    }
    @MainActor static func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }
    @MainActor static func workbench() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = PresentationStore()
        let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: store)
        let model = root.workbench
        let surface = Surface(WorkbenchView(model: model, connectionSettings: root.connectionSettings))
        defer { surface.dispose() }
        try await settle()
        try expectPresentation(store.count == 0 && model.grants.isEmpty, "view performed storage IO or invented a grant")
        try expectPresentation(try surface.contains(root.connectionSettings.status), "initial connection availability not rendered")
        let scope = try ResourceScope(service: "files", resource: "report-alpha.txt", operation: "write")
        let denied = try ResourceScope(service: "files", resource: "report-beta.txt", operation: "write")
        let id = UUID()
        let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-1), expiresAt: Date().addingTimeInterval(900), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "presentation-fixture", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: [scope, denied])], explicitDenies: [denied], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 8192, concurrentRequests: 1))
        try await model.installTrustedGrant(grant)
        let binding = try ActionBinding(runID: grant.runID, epoch: 1, grantDigest: RunAuthorizationController.grantDigest(for: grant), connectionID: id, operation: "write", schemaDigest: String(repeating: "c", count: 64), resolvedResource: scope.resource, canonicalRequest: Data(#"{"value":1}"#.utf8))
        let pending = try await model.proposeTrustedAction(binding: binding, display: "Synthetic immutable report")
        try await model.recordGuestDiagnostic(runID: grant.runID, operation: "observe", resource: "fixture", message: "synthetic guest observation")
        try await settle()
        try expectPresentation(try surface.contains("report-alpha.txt") && surface.contains("report-beta.txt"), "granted scopes missing from rendered workbench")
        try expectPresentation(model.pending == [pending] && model.approvedActions.isEmpty, "rendering changed approval state")
        try surface.click("Review")
        try await settle()
        guard let sheet = surface.window.attachedSheet?.contentView else { throw PresentationFailure(message: "review did not show approval sheet") }
        try await Task.sleep(for: .milliseconds(400))
        try expectPresentation(try surface.contains("Synthetic immutable report", in: sheet), "sheet lost immutable display snapshot")
        try surface.click("Deny", in: sheet)
        try await settle()
        try expectPresentation(model.pending.isEmpty && model.approvedActions.isEmpty && model.trustedDenialCount > 0, "Deny control failed closed")
        print("PASS workbench renders granted scopes and pending snapshot; real Review and Deny controls update authority")
        for control in ["Approve once", "Cancel / deny"] {
            _ = try await model.proposeTrustedAction(binding: binding, display: "Synthetic immutable report")
            try await settle()
            try surface.click("Review")
            try await Task.sleep(for: .milliseconds(400))
            guard let content = surface.window.attachedSheet?.contentView else { throw PresentationFailure(message: "review sheet missing") }
            try surface.click(control, in: content)
            try await Task.sleep(for: .milliseconds(400))
            try expectPresentation(model.pending.isEmpty && model.approvedActions.count == 1, "approval/cancel did not preserve exactly one capability")
        }
        try expectPresentation(!model.activity.contains { $0.reason == "dispatch-intent" }, "view auto-dispatched approved action")
        let settings = Surface(ConnectionSettingsView(controller: root.connectionSettings), width: 1000, height: 500)
        defer { settings.dispose() }
        try await settle()
        try settings.enterCredential("synthetic-only")
        try await settle()
        try settings.click("Save to Keychain")
        try await settle()
        try expectPresentation(root.connectionSettings.configuration != nil && surface.contains("account version"), "future configuration missing from rendered settings")
        try expectPresentation(!settings.contains("synthetic-only"), "secure input leaked into rendered pixels")
        let calls = store.count
        try settings.click("Check stored credential")
        try await settle()
        try expectPresentation(store.count == calls + 1 && root.connectionSettings.configuration != nil, "Check control did not validate synthetic storage")
        // Delete's destructive-button click-through behavior requires a full
        // external GUI acceptance run. Here exercise its real controller and
        // verify both product views remove the routing metadata.
        await root.connectionSettings.deleteStoredCredential()
        try await settle()
        try expectPresentation(root.connectionSettings.configuration == nil && !settings.contains("account version"), "deleted routing remained visible")
        try surface.click("Stop and revoke")
        try await settle()
        try expectPresentation(!model.canStop(runID: grant.runID) && model.approvedActions.isEmpty, "Stop control left run or capability active")
        let closed = await root.close()
        try expectPresentation(closed, "composition did not close")
        print("PASS approval/cancel never dispatch; Save/Check controls, deletion projection and emergency Stop bind actual state")
    }
    @MainActor static func environment() async throws {
        let surface = Surface(EnvironmentView(), width: 1000, height: 700)
        defer { surface.dispose() }
        try await settle()
        try surface.click("Run environment check")
        for _ in 0..<30 {
            try await settle()
            if try surface.contains("arm64") {
                print("PASS environment refresh renders actual host architecture")
                return
            }
        }
        throw PresentationFailure(message: "environment refresh never rendered host report")
    }
}
