"""Compile-time API boundary checks; run after `swift build`."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

class PublicAPITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.modules = Path(subprocess.check_output(
            ["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip()) / "Modules"

    def compile(self, body):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR", str(ROOT / ".build"))) as directory:
            source = Path(directory) / "Client.swift"
            source.write_text("import Foundation\nimport SandboxContracts\nimport SandboxHost\n" + body)
            return subprocess.run(["xcrun", "swiftc", "-typecheck", "-I", str(self.modules), str(source)],
                                  cwd=ROOT, text=True, capture_output=True)

    def test_public_types_are_importable(self):
        result = self.compile("func inspect(_ grant: RunGrant, _ action: PendingAction, _ event: SecurityEvent) { _ = event.origin }\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_client_cannot_construct_host_enforcement_event(self):
        result = self.compile('''let event = try SecurityEvent(eventID: UUID(), hostSequence: 1,
            runID: UUID(), actionID: nil, time: Date(), origin: .hostEnforcement,
            operation: "write", resourceSummary: "repo", decision: .deny,
            reason: "denied", grantDigest: String(repeating: "a", count: 64), outcome: .notDispatched)
''')
        self.assertNotEqual(result.returncode, 0, "Public caller could forge host enforcement provenance")
        self.assertIn("inaccessible", result.stderr)

    def test_host_event_provenance_filter(self):
        # Compile the actual internal event model with a same-module harness.
        # Public clients cannot do this; this exercises the trusted module's behavior.
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR", str(ROOT / ".build"))) as directory:
            folder = Path(directory)
            source = folder / "main.swift"
            source.write_text('''import Foundation
import SandboxContracts
let now = Date()
func event(_ origin: EventOrigin, _ outcome: DispatchOutcome) throws -> SecurityEvent {
    try SecurityEvent(eventID: UUID(), hostSequence: 1, runID: UUID(), actionID: nil,
        time: now, origin: origin, operation: "read", resourceSummary: "workspace",
        decision: .deny, reason: "reported", grantDigest: String(repeating: "e", count: 64), outcome: outcome)
}
let guest = try event(.guestDiagnostic, .notDispatched)
precondition(!guest.isHostRejection)
let host = try event(.hostEnforcement, .notDispatched)
precondition(host.isHostRejection)
let unknown = try event(.hostEnforcement, .unknown)
precondition(!unknown.isHostRejection)
print("PASS guest diagnostic excluded; host rejection requires notDispatched")
''')
            executable = folder / "EventChecks"
            objects = sorted((self.modules.parent / "SandboxContracts.build").glob("*.swift.o"))
            self.assertTrue(objects)
            compile_result = subprocess.run(["xcrun", "swiftc", "-I", str(self.modules),
                str(ROOT / "Sources/SandboxHost/SecurityEvent.swift"), str(source),
                *map(str, objects), "-o", str(executable)], cwd=ROOT, text=True, capture_output=True)
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run([str(executable)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_action_and_event_are_not_guest_decodable(self):
        for name in ("PendingAction", "SecurityEvent"):
            with self.subTest(type=name):
                result = self.compile(f'let object = try JSONDecoder().decode({name}.self, from: Data())\n')
                self.assertNotEqual(result.returncode, 0, f"{name} became Decodable")
                self.assertIn("Decodable", result.stderr)

if __name__ == "__main__":
    unittest.main()
