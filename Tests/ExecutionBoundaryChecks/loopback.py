#!/usr/bin/env python3
"""Offline real-MCP receiver slice. Synthetic bearer only through stdin."""

import json
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests/MCPIntegrationTests"))
from test_loopback import running_fixture, mint

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, default=ROOT / ".build/debug/ExecutionBoundaryChecks")
parser.add_argument("--transaction", action="store_true")
args = parser.parse_args()
transaction = args.transaction

with running_fixture() as fixture:
    token = mint(fixture)
    before = fixture.control.resource_hit_count
    result = subprocess.run(
        [str(args.binary), "--mcp-transaction" if transaction else "--mcp"],
        input=json.dumps({"port": fixture.resource.server.server_address[1], "token": token}) + "\n",
        text=True,
        capture_output=True,
        timeout=30,
    )
    lines = result.stdout.splitlines()
    expected = {
        "PASS actual-mcp-accept credential_reads=4 actual_resume_calls=4 accepted_tool_results=1",
        "PASS actual-mcp-stop credential_reads=4 actual_resume_calls=4 accepted_tool_results=0",
    }
    if transaction:
        expected = {
            "PASS actual-mcp-ingress-transaction invalid_cases=5 invalid_reads=0 invalid_resumes=0 credential_reads=5 actual_resume_calls=5 completions=5 accepted_tool_results=1"
        }
    if result.returncode != 0 or set(lines) != expected or len(lines) != len(expected):
        for line in lines:
            if line.startswith("FAIL "):
                print(line)
        raise SystemExit("FAIL controlled MCP child")
    if fixture.control.resource_hit_count - before != (5 if transaction else 8):
        raise SystemExit("FAIL controlled MCP ingress count")
    for line in lines:
        print(line)
    print(
        "PASS actual-mcp-transaction-independent-ingress http_arrivals=5 invalid_http_arrivals=0"
        if transaction
        else "PASS actual-mcp-independent-ingress http_arrivals=8 distinct_cases=2"
    )
