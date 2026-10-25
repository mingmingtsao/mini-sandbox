"""Require semantic check results as well as an AppKit process's exit status."""
import argparse
from pathlib import Path
import subprocess

EXPECTED = {
    "PASS business task selection consent agent gates and MCP metadata projection; production route stays disabled",
    "PASS unavailable workbench pixels expose authority failure and no pending actions",
    "PASS workbench renders granted scopes and pending snapshot; real Review and Deny controls update authority",
    "PASS approval/cancel never dispatch; Save/Check controls, deletion projection and emergency Stop bind actual state",
    "PASS environment refresh renders actual host architecture",
    "PASS all presentation checks",
}


def validate(result):
    lines = result.stdout.splitlines()
    if result.returncode or not EXPECTED.issubset(lines) or any(line.startswith(("FAIL", "BLOCKED")) for line in lines):
        raise ValueError("presentation process failed or did not complete every semantic check")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    result = subprocess.run([str(parser.parse_args().binary)], capture_output=True, text=True, timeout=90)
    try:
        validate(result)
    except ValueError:
        print(result.stdout[-12000:])
        print(result.stderr[-6000:])
        raise
    print(result.stdout, end="")


if __name__ == "__main__":
    main()
