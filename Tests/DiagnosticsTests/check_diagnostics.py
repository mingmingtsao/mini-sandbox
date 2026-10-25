"""Exercise the packaged app's read-only environment CLI without opening a GUI."""

import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, required=True)
args = parser.parse_args()
result = subprocess.run(
    [str(args.binary), "--diagnostics-json"], check=True, capture_output=True, text=True, timeout=30
)
report = json.loads(result.stdout)
assert report["architecture"] == "arm64"
assert report["logicalCPUCount"] > 0 and report["physicalMemoryBytes"] > 0
assert isinstance(report["operatingSystem"], str) and report["operatingSystem"]
assert isinstance(report["virtualizationSupported"], bool)
assert isinstance(report["keychainStatus"], int)
assert report["keychainQueryAvailable"] == (report["keychainStatus"] in (0, -25300))
assert "checkedAt" in report
assert set(report) <= {
    "architecture",
    "logicalCPUCount",
    "physicalMemoryBytes",
    "availableDiskBytes",
    "operatingSystem",
    "virtualizationSupported",
    "keychainQueryAvailable",
    "keychainStatus",
    "checkedAt",
}
print("PASS app environment diagnostics schema and host capability invariants")
print("OBS host capabilities virtualization_supported=" + str(report["virtualizationSupported"]).lower())
