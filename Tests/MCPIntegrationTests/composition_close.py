#!/usr/bin/env python3
"""Composition MCP close/settlement; original authenticated loopback handler."""
import json
import argparse
from pathlib import Path
import subprocess
import threading
import time

from test_loopback import running_fixture, mint, child_lines
from host_services import _ResourceHandler

ROOT = Path(__file__).resolve().parents[2]
NAMES = {"queued", "running", "completion-failure", "unknown-failure"}


def run(binary):
    with running_fixture() as fixture:
        token = mint(fixture)
        mode = {"hold": False}
        entered, release = threading.Event(), threading.Event()
        observations = {"timeout": False}

        class Boundary(_ResourceHandler):
            def _begin(self):
                self.hold_response = mode["hold"]
                super()._begin()

            def _mcp_result(self, request_id, result):
                if self.hold_response:
                    entered.set()
                    if not release.wait(5):
                        observations["timeout"] = True
                super()._mcp_result(request_id, result)

        fixture.resource.server.RequestHandlerClass = Boundary
        process = subprocess.Popen([str(binary), "--composition-mcp"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=ROOT)
        assert process.stdin is not None and process.stdout is not None
        seen, cases, failed = set(), set(), False
        active = None
        try:
            process.stdin.write((json.dumps({"port": fixture.resource.server.server_address[1], "token": token}) + "\n").encode())
            process.stdin.flush()
            for line in child_lines(process, time.monotonic() + 60, 10):
                words = line.split()
                if words[0] in {"BEGIN", "ARM", "WAIT", "RELEASE"}:
                    action, name = words
                    assert name in NAMES
                    if action == "BEGIN":
                        assert active is None and name not in cases
                        active = name; cases.add(name)
                        fixture.control.reset(); mode["hold"] = False
                        entered.clear(); release.clear()
                    else:
                        assert name == active
                        if action == "ARM":
                            mode["hold"] = name != "queued"
                        elif action == "WAIT":
                            assert entered.wait(5), "actual authenticated response boundary not reached"
                            assert fixture.control.resource_hit_count == 4
                        else:
                            release.set()
                    process.stdin.write(b"go\n"); process.stdin.flush()
                elif line.startswith("OBS MCP "):
                    assert words[2] == active
                    assert fixture.control.resource_hit_count == 4, "unexpected HTTP ingress count"
                    assert not observations["timeout"], "response barrier timed out"
                    print(line + " http_arrivals=4", flush=True)
                elif line.startswith(("PASS composition MCP ", "FAIL composition MCP ")):
                    name = words[3].rstrip(":")
                    assert name == active and name not in seen
                    seen.add(name); active = None
                    failed |= line.startswith("FAIL")
                    print(line, flush=True)
                elif line.startswith("FAIL:"):
                    failed = True
                    print(line, flush=True)
                else:
                    raise AssertionError("unexpected child protocol")
            assert seen == cases == NAMES and not failed, "incomplete/failed case set"
            print("PASS composition MCP independent ingress cases=4 http_arrivals=16", flush=True)
        finally:
            release.set()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=2)
            process.stdin.close(); process.stdout.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/debug/WorkbenchChecks")
    run(parser.parse_args().binary)
