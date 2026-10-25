#!/usr/bin/env python3
"""Build the fixed workspace fixture or native receive checks, never guest code.

Run through the coordinator's build queue when one is required. The new private
output directory must not exist. No signing, VM launch, credentials or network.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in {"fixture", "runtime-checks", "runtime-probe", "business-probe", "business-fixture", "permission-clock"}:
        raise SystemExit("usage: build_host.py fixture|runtime-checks|runtime-probe|business-probe|business-fixture|permission-clock NEW_OUTPUT_DIRECTORY")
    root = Path(__file__).resolve().parents[2]
    out = Path(sys.argv[2]).absolute()
    os.umask(0o077)
    out.mkdir(mode=0o700)  # Exclusive new artifacts; never overwrite prior evidence.
    subprocess.run(["swift", "build", "--target", "SandboxContracts"], cwd=root, check=True)
    binary_dir = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=root, text=True).strip())
    entries = {
        "fixture": "Tools/WorkspaceTransfer/main.swift",
        "runtime-checks": "Tests/AgentRuntimeTests/RuntimeReceiveTests.swift",
        "runtime-probe": "Tools/AgentRuntime/main.swift",
        "business-probe": "Tools/AgentRuntime/BusinessVMProbe.swift",
        "business-fixture": "Tools/AgentRuntime/BusinessFixtureProbe.swift",
        "permission-clock": "Tests/BusinessVMSecurityChecks/PermissionClockProbe.swift",
    }
    # Compile the real shared authority/lifecycle, not a stub or duplicated grant.
    sources = sorted((root / "Sources/SandboxHost").glob("*.swift")) + [root / entries[sys.argv[1]]]
    objects = sorted((binary_dir / "SandboxContracts.build").glob("*.swift.o"))
    if not sources or not objects:
        raise SystemExit("missing concrete host/contract build inputs")
    entry_flags = [] if sys.argv[1] == "runtime-probe" else ["-parse-as-library"]
    fixture_flags = ["-DSANDBOX_TEST_FIXTURES", "-enable-testing"] if sys.argv[1] in {"business-probe", "business-fixture", "permission-clock"} else []
    command = ["swiftc", *entry_flags, *fixture_flags, "-package-name", "MiniSandbox", "-swift-version", "6", "-I", str(binary_dir / "Modules"), *map(str, sources), *map(str, objects), "-o", str(out / "host")]
    print(json.dumps({"command": command}), flush=True)
    subprocess.run(command, cwd=root, check=True)
    hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    hashes["host"] = hashlib.sha256((out / "host").read_bytes()).hexdigest()
    (out / "build.json").write_text(json.dumps({"mode": sys.argv[1], "command": command, "sha256": hashes}, indent=2) + "\n")


if __name__ == "__main__":
    main()
