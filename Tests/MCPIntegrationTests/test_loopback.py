#!/usr/bin/env python3
"""Real loopback driver for the host integration executable.
No token in argv, environment, files, or transcript; synthetic token crosses stdin.
"""
import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import socket
import subprocess
import sys
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests/Fixtures/host_services"))
from host_services import HostFixture, _ResourceHandler
from test_host_services import request, json_request
from response_gates import ResponseGates, independent_phases


def mint(fixture):
    verifier = "v" * 43
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    params = dict(response_type="code", client_id="fixture-client", redirect_uri="http://127.0.0.1/callback", resource=fixture.resource.origin, code_challenge=challenge, code_challenge_method="S256", state="fixture-state")
    status, headers, _ = request(fixture.auth.origin + "/oauth/authorize?" + urllib.parse.urlencode(params))
    assert status == 302
    code = urllib.parse.parse_qs(urllib.parse.urlsplit(headers["Location"]).query)["code"][0]
    form = urllib.parse.urlencode(dict(grant_type="authorization_code", code=code, client_id="fixture-client", redirect_uri="http://127.0.0.1/callback", code_verifier=verifier, resource=fixture.resource.origin)).encode()
    status, _, body = request(fixture.auth.origin + "/oauth/token", "POST", form, {"Content-Type": "application/x-www-form-urlencoded"})
    assert status == 200
    return json.loads(body)["access_token"]


def rpc(fixture, token, name, repo, content=None):
    args = {"repo": repo}
    if content is not None:
        args["content"] = content
    status, _, body = json_request(fixture.resource.origin + "/mcp", "POST", {"jsonrpc": "2.0", "id": "direct", "method": "tools/call", "params": {"name": name, "arguments": args}}, token)
    assert status == 200
    return json.loads(body)["result"]["content"][0]["text"]


from contextlib import contextmanager

@contextmanager
def running_fixture():
    fixture = HostFixture.start()
    try:
        yield fixture
    finally:
        fixture.stop()


class DriverFailure(Exception):
    """Only static messages; never include a response, credential or child line."""


def child_lines(process, deadline, inactivity_timeout):
    """Bound pipe reading itself, including silent children and EOF-before-exit."""
    last_activity = time.monotonic()
    pending = b""
    total = 0
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while True:
            now = time.monotonic()
            if now >= deadline:
                raise DriverFailure("overall deadline exceeded")
            if now >= last_activity + inactivity_timeout:
                raise DriverFailure("inactivity deadline exceeded")
            ready = selector.select(min(deadline - now, last_activity + inactivity_timeout - now))
            if not ready:
                continue
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            last_activity = time.monotonic()
            total += len(chunk)
            pending += chunk
            if total > 262144 or len(pending) > 8192:
                raise DriverFailure("child output limit exceeded")
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                if time.monotonic() >= deadline:
                    raise DriverFailure("overall deadline exceeded")
                try:
                    yield line.decode("ascii")
                except UnicodeDecodeError:
                    raise DriverFailure("invalid child output") from None
        if pending:
            raise DriverFailure("unterminated child output")
        now = time.monotonic()
        remaining = min(deadline - now, last_activity + inactivity_timeout - now)
        try:
            status = process.wait(timeout=max(0.001, remaining))
        except subprocess.TimeoutExpired:
            label = "overall" if deadline <= last_activity + inactivity_timeout else "inactivity"
            raise DriverFailure(label + " deadline exceeded") from None
        if status != 0:
            raise DriverFailure(f"executable exited {status}")


def expected_phases():
    expected = set(["discovery", "approved-read", "denied-ingress", "model-handoff", "write-discovery", "denied-write", "approved-write", "wrong-id", "http-status", "tool-error", "rpc-error", "redirect", "drop-write", "catalog-replacement", "empty-catalog"])
    for kind in ["intent-audit", "completion-audit", "stop", "revoke", "account", "route", "cancel", "barrier-stop", "barrier-revoke", "barrier-cancel", "barrier-expiry", "completion-stop"]:
        expected.update([kind, kind + "-discovery"])
    expected.update(["frozen-args", "schema-change", "catalog-reload"])
    expected.update("reflection-" + kind for kind in ["plain", "authorization", "escaped", "split", "ordinary", "unrelated-bearer"])
    for kind in ["credential-binding", "credential-provider", "disk-completed", "disk-reflection", "disk-intent-failure", "disk-completion-failure"]:
        expected.update([kind, kind + "-discovery"])
    for cap in ("grant", "hard"):
        expected.add("limit-" + cap + "-discovery")
        expected.update("limit-" + cap + "-" + framing + "-" + edge
                        for framing in ("declared", "unknown", "chunked") for edge in ("exact", "over"))
    expected.add("text-limit-discovery")
    expected.update("pulse-" + operation + "-" + str(position)
                    for operation, positions in (("propose", 4), ("approve", 3), ("deny", 3))
                    for position in range(1, positions + 1))
    expected.update("text-limit-" + shape + "-" + edge
                    for shape in ("single", "split") for edge in ("exact", "over"))
    return expected


def run(binary, *, overall_timeout=90, inactivity_timeout=10, scope="default"):
    if not all(math.isfinite(value) and value > 0 for value in (overall_timeout, inactivity_timeout)):
        raise DriverFailure("invalid deadline")
    deadline = time.monotonic() + overall_timeout
    expected = independent_phases() if scope == "independent" else expected_phases()
    with running_fixture() as fixture, running_fixture() as second:
        token = mint(fixture)
        # Same upstream bearer intentionally authorizes BOTH repositories and operations.
        for repo in ("A", "B"):
            assert rpc(fixture, token, "repo_read", repo) == f"repo-{repo}-initial"
            assert rpc(fixture, token, "repo_write", repo, f"repo-{repo}-initial") == f"repo-{repo}-initial"
        assert fixture.control.resource_hit_count == 4
        print("PASS direct-upstream-A-B-read-write hits=4", flush=True)
        mode = {"value": "", "dropped": 0, "redirected": 0, "json_accept_only": True}

        class FaultBoundary(_ResourceHandler):
            """Additive same-origin response boundary AFTER unchanged MCP handler.
            Bearer, audience, routing and Host checks run in the original handler.
            No forwarding, no altered upstream permissions, no callback assertions.
            """
            def _begin(self):
                self.test_fault = mode["value"]  # Capture once per request, never a later phase.
                self.test_gate = mode.get("gate")
                if self.path == "/mcp":
                    mode["json_accept_only"] = mode["json_accept_only"] and self.headers.get("Accept") == "application/json"
                super()._begin()

            def _mcp_result(self, request_id, result):
                fault = self.test_fault
                if self.test_gate and self.test_gate.cap:
                    if self.test_gate.hold():
                        self._send(503, {"error": "bounded-test-failure"})
                        return
                if (fault.startswith("limit-") or fault.startswith("text-limit-")) and not fault.endswith("discovery"):
                    parts = ["boundary-control"]
                    framing = "declared"
                    cap = ""
                    if fault.startswith("text-limit-"):
                        _, _, shape, edge = fault.split("-")
                        parts = ["é" * 16384] if shape == "single" else ["é" * 8192, "é" * 8192]
                        if edge == "over":
                            parts[-1] += "a"
                    else:
                        _, cap, framing, edge = fault.split("-")
                    payload = {"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": part} for part in parts], "isError": False}}
                    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
                    if fault.startswith("limit-"):
                        length = (4096 if cap == "grant" else 65536) + (edge == "over")
                        body += b" " * (length - len(body))
                    mode["boundary_observations"].append((fault, len(body), sum(len(p.encode()) for p in parts), framing))
                    self.protocol_version = "HTTP/1.1"
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Connection", "close")
                    if framing == "declared":
                        self.send_header("Content-Length", str(len(body)))
                    elif framing == "chunked":
                        self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers(); self._record(200)
                    self.close_connection = True
                    try:
                        for start in range(0, len(body), 1024):
                            chunk = body[start:start + 1024]
                            if framing == "chunked":
                                self.wfile.write(("%x\r\n" % len(chunk)).encode() + chunk + b"\r\n")
                            else:
                                self.wfile.write(chunk)
                            self.wfile.flush()
                        if framing == "chunked":
                            self.wfile.write(b"0\r\n\r\n")
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
                if fault == "disk-reflection":
                    fault = "reflection-split"
                if fault.startswith("reflection-"):
                    active = self.headers.get("Authorization", "").removeprefix("Bearer ")
                    parts = [active]
                    if fault == "reflection-authorization":
                        parts = ["Authorization: Bearer " + active]
                    elif fault == "reflection-split":
                        middle = len(active) // 2
                        parts = [active[:middle], active[middle:]]
                    elif fault == "reflection-ordinary":
                        parts = ["ordinary non-reflecting content"]
                    elif fault == "reflection-unrelated-bearer":
                        parts = ["Bearer unrelated-public-word"]
                    result = {"content": [{"type": "text", "text": part} for part in parts], "isError": False}
                    if fault == "reflection-escaped":
                        encoded = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result})
                        encoded = encoded.replace(active, "".join("\\u%04x" % ord(ch) for ch in active))
                        self._send(200, encoded.encode())
                        return
                if fault in ("drop-write", "negative-model-drop-write"):
                    mode["dropped"] += 1
                    self.close_connection = True
                    try:
                        self.connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    self.connection.close()
                    return
                if fault == "redirect":
                    mode["redirected"] += 1
                    self.send_response(307)
                    self.send_header("Location", second.resource.origin + "/mcp")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    self._record(307)
                    return
                if fault == "wrong-id":
                    request_id = "not-the-approved-id"
                if fault == "http-status":
                    self._send(503, {"error": "test-only"})
                    return
                if fault == "tool-error":
                    result = {"content": [{"type": "text", "text": "error"}], "isError": True}
                if fault == "rpc-error":
                    self._send(200, {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": "test-only"}})
                    return
                if fault == "schema-change":
                    result["tools"][0]["inputSchema"] = {"type": "object", "properties": {"repo": {"type": "string"}}}
                if fault == "empty-catalog":
                    result = {"tools": []}
                super()._mcp_result(request_id, result)

        fixture.resource.server.RequestHandlerClass = FaultBoundary
        process = subprocess.Popen([str(binary)] + (["--independent"] if scope == "independent" else []), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=ROOT)
        assert process.stdin and process.stdout
        results = {}
        model_results = {}
        active_phase = None
        credential_total = 0
        try:
            process.stdin.write((json.dumps({"port": fixture.resource.server.server_address[1], "token": token}) + "\n").encode())
            process.stdin.flush()
            for line in child_lines(process, deadline, inactivity_timeout):
                if line.startswith("SYNC "):
                    _, name, before = line.split()
                    assert name in expected, "unknown phase"
                    assert active_phase is None and int(before) == credential_total, "unreported credential access"
                    active_phase = name
                    fixture.control.reset(); second.control.reset()
                    mode["value"] = name
                    mode["gate"] = ResponseGates(name)
                    mode["boundary_observations"] = []
                    if name in ("drop-write", "negative-model-drop-write"):
                        # A distinct prior value proves the MCP mutation precedes loss.
                        with fixture.resource.server.fixture_state.lock:
                            fixture.resource.server.fixture_state.repos["A"] = "before-uncertain-write"
                    process.stdin.write(b"go\n"); process.stdin.flush()
                elif line.startswith("GATE "):
                    assert scope == "independent" and active_phase is not None
                    _, action, value = line.split()
                    mode["gate"].command(action, value, fixture.control.resource_hit_count)
                    process.stdin.write(b"go\n"); process.stdin.flush()
                elif re.fullmatch(r"MODEL negative-model-(B|write|denied|unapproved|non-tool|truncated|provisional|failure|drop-write) requests=1 credential_reads=1 terminal=0", line):
                    name = line.split()[1]
                    assert scope == "independent" and name == active_phase and name not in model_results
                    model_results[name] = {"offline_requests": 1, "credential_reads": 1, "terminal_callbacks": 0}
                    print(line, flush=True)
                elif line.startswith("CHECK "):
                    _, name, hits, reads, before, after, expected_reads = line.split()
                    assert name not in results, "duplicate test name"
                    assert active_phase == name, "phase/report mismatch"
                    assert int(before) == credential_total
                    assert int(after) - int(before) == int(reads) == int(expected_reads), "credential delta mismatch"
                    credential_total = int(after)
                    active_phase = None
                    actual = fixture.control.resource_hit_count
                    mode["gate"].verify()
                    assert actual == int(hits), (name, "hits", actual, int(hits))
                    if not mode["json_accept_only"]:
                        raise DriverFailure("JSON-only client advertised unsupported transport")
                    assert second.control.resource_hit_count == 0, "redirect leaked request/credential"
                    if (name.startswith("limit-") or name.startswith("text-limit-")) and not name.endswith("discovery"):
                        observations = mode["boundary_observations"]
                        assert len(observations) == 1 and observations[0][0] == name
                        if name.startswith("limit-"):
                            _, cap, framing, edge = name.split("-")
                            assert observations[0][1] == (4096 if cap == "grant" else 65536) + (edge == "over")
                            assert observations[0][3] == framing
                        else:
                            assert observations[0][2] == 32768 + name.endswith("over")
                    if name in ("drop-write", "negative-model-drop-write"):
                        assert mode["dropped"] == 1, "write retried"
                        mode["value"] = ""
                        status, _, body = json_request(fixture.resource.origin + "/v1/repos/A", token=token)
                        assert status == 200 and json.loads(body)["content"] == "changed"
                        assert fixture.control.resource_hit_count == 2, "one write plus independent verification"
                    results[name] = {"hits": actual, "credential_reads": int(reads), "reads_before": int(before), "reads_after": int(after)}
                    print("PASS " + name + f" hits={actual} reads={reads}", flush=True)
                elif re.fullmatch(r"CLOCK pulse-(propose|approve|deny)-[1-4] samples=[0-9]+ fired=(true|false) latched=(true|false) repaired=(true|false) audit_expired=(true|false) error=(none|revoked|grant-expired) reads=[0-9]+", line):
                    assert active_phase is not None and line.split()[1] == active_phase
                    print(line, flush=True)
                elif line == "FAIL MCP pulse sampled expiry did not latch":
                    print(line, flush=True)
                    print(json.dumps({"partial": True, "completed_phases": len(results), "gateway_hits": sum(row["hits"] for row in results.values()), "credential_reads": credential_total, "failed_phase": active_phase, "failed_phase_hits": fixture.control.resource_hit_count, "results": results}, sort_keys=True), flush=True)
                    raise DriverFailure("grant-expiry pulse regression")
                elif line in ("PASS MCP loopback checks", "PASS MCP independent scope; full suite known RED pulse-deny-2") or re.fullmatch(r"REFLECTION reflection-(plain|authorization|escaped|split) completion_blocked=(true|false) handoff_blocked=(true|false) unknown=(true|false) audit_unknown=(true|false)", line):
                    print(line, flush=True)
                else:
                    raise DriverFailure("unexpected child output or failed check")
            assert active_phase is None
            assert mode["redirected"] == (0 if scope == "independent" else 1) and mode["dropped"] == 1
            assert set(results) == expected, ("result set mismatch", sorted(set(results) ^ expected))
            if scope == "independent":
                assert set(model_results) == {"negative-model-" + name for name in ("B", "write", "denied", "unapproved", "non-tool", "truncated", "provisional", "failure", "drop-write")}
            assert sum(row["credential_reads"] for row in results.values()) == credential_total
            print(json.dumps({"scope": scope, "full_suite": "KNOWN_RED_pulse-deny-2", "deduplicated_checks": len(results), "gateway_hits": sum(row["hits"] for row in results.values()), "credential_reads": credential_total, "offline_model_results": model_results, "results": results}, sort_keys=True))
        finally:
            if process.poll() is None:
                process.kill(); process.wait(timeout=2)
            process.stdin.close(); process.stdout.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/debug/MCPGatewayChecks")
    parser.add_argument("--overall-timeout", type=float, default=90)
    parser.add_argument("--inactivity-timeout", type=float, default=10)
    parser.add_argument("--scope", choices=("default", "independent"), default="default")
    args = parser.parse_args()
    try:
        run(args.binary, overall_timeout=args.overall_timeout, inactivity_timeout=args.inactivity_timeout, scope=args.scope)
    except DriverFailure as error:
        print("FAIL driver " + str(error), flush=True)
        sys.exit(1)
    except Exception:
        print("FAIL driver assertion or setup failure", flush=True)
        sys.exit(1)
