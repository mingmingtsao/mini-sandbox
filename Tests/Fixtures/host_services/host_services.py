"""Executable local host-loopback fixtures for OAuth, MCP, and a resource API.

This module is deliberately a test fixture. It contains no Broker or policy gate.
"""

from __future__ import annotations

import base64
import hashlib
import http.server
import json
import secrets
import socket
import threading
import time
import urllib.parse
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple


FIXED_PROTOCOL_VERSION = "2025-03-26"
MAX_BODY_BYTES = 64 * 1024
ACCESS_TTL_SECONDS = 300
REFRESH_TTL_SECONDS = 3600
CLIENT_ID = "fixture-client"
REGISTERED_REDIRECT_URI = "http://127.0.0.1/callback"


class DuplicateJSONKey(ValueError):
    pass


def _reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJSONKey("duplicate JSON object key")
        result[key] = value
    return result


def parse_json_body(body: bytes) -> Any:
    return json.loads(body.decode("utf-8"), object_pairs_hook=_reject_duplicate_keys)


def _form(value: str):
    pairs = urllib.parse.parse_qsl(value, strict_parsing=True, keep_blank_values=True, max_num_fields=32)
    result = {}
    for key, item in pairs:
        if key in result:
            raise ValueError("duplicate parameter")
        result[key] = [item]
    return result


def _json_bytes(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


def _b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


class FixtureControl:
    """Safe test controls; transcript values never include request secrets or bodies."""

    def __init__(self, state: "FixtureState"):
        self._state = state

    @property
    def resource_hit_count(self) -> int:
        with self._state.lock:
            return self._state.resource_hits

    def transcripts(self) -> List[dict]:
        with self._state.lock:
            return [dict(item) for item in self._state.transcripts]

    def reset(self) -> None:
        with self._state.lock:
            self._state.transcripts.clear()
            self._state.resource_hits = 0
            self._state.faults.clear()

    def set_fault(self, service: str, mode: str) -> None:
        if service not in ("auth", "resource"):
            raise ValueError("unknown service")
        if mode not in ("401", "500", "connection_close", "timeout", "write_then_disconnect"):
            raise ValueError("unknown fault")
        with self._state.lock:
            self._state.faults[service] = mode

    def clear_fault(self, service: str) -> None:
        with self._state.lock:
            self._state.faults.pop(service, None)

    def expire_access(self, access_token: str) -> None:
        with self._state.lock:
            grant = self._state.access_tokens.get(access_token)
            if grant:
                grant["expires_at"] = 0.0

    def revoke(self, access_token: str) -> None:
        with self._state.lock:
            grant = self._state.access_tokens.get(access_token)
            if grant:
                grant["revoked"] = True


class FixtureState:
    def __init__(self):
        self.lock = threading.RLock()
        self.auth_origin = ""
        self.resource_origin = ""
        self.codes: Dict[str, dict] = {}
        self.access_tokens: Dict[str, dict] = {}
        self.refresh_tokens: Dict[str, dict] = {}
        self.repos = {"A": "repo-A-initial", "B": "repo-B-initial"}
        self.transcripts: List[dict] = []
        self.resource_hits = 0
        self.faults: Dict[str, str] = {}

    def record(self, service: str, method: str, path: str, status: int) -> None:
        with self.lock:
            if service == "resource":
                self.resource_hits += 1
            self.transcripts.append({"service": service, "method": method, "path": path, "status": status})


class _Server(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class _Handler(http.server.BaseHTTPRequestHandler):
    service = ""

    server: _Server

    def log_message(self, fmt, *args):
        # Deliberately suppress request lines: they can contain authorization data.
        return

    @property
    def state(self) -> FixtureState:
        return self.server.fixture_state  # type: ignore[attr-defined]

    def _expected_host(self) -> str:
        return urllib.parse.urlsplit(self.server.origin).netloc  # type: ignore[attr-defined]

    def _host_ok(self) -> bool:
        # HTTP/1.1 requires Host. Exact host and port prevents cross-origin fixture use.
        return self.headers.get_all("Host", []) == [self._expected_host()]

    def _fault(self) -> Optional[str]:
        with self.state.lock:
            return self.state.faults.get(self.service)

    def setup(self):
        super().setup()
        self.connection.settimeout(2.0)

    def _begin(self):
        # Count parsed HTTP requests reaching method dispatch, before auth/response.
        # Parser failures and incomplete TCP traffic never reach this point.
        with self.state.lock:
            if self.service == "resource":
                self.state.resource_hits += 1
            self._entry = {"service": self.service, "method": self.command,
                           "path": urllib.parse.urlsplit(self.path).path, "status": None}
            self.state.transcripts.append(self._entry)

    def _record(self, status: int) -> None:
        with self.state.lock:
            if hasattr(self, "_entry"):
                self._entry["status"] = status

    def _send(self, status: int, payload: Any, content_type: str = "application/json") -> None:
        data = payload if isinstance(payload, bytes) else _json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self._record(status)
        try:
            if self.command != "HEAD":
                self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def _error(self, status: int, error: str, detail: str = "") -> None:
        payload = {"error": error}
        if detail:
            payload["detail"] = detail
        self._send(status, payload)

    def _read_body(self) -> Optional[bytes]:
        if self.headers.get("Transfer-Encoding") or len(self.headers.get_all("Content-Length", [])) != 1:
            self._error(400, "invalid_framing")
            return None
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            self._error(400, "invalid_request", "Content-Length is required")
            return None
        try:
            length = int(raw_length)
        except ValueError:
            self._error(400, "invalid_request", "invalid Content-Length")
            return None
        if length < 0 or length > MAX_BODY_BYTES:
            self._error(413, "body_too_large")
            return None
        try:
            data = self.rfile.read(length)
        except (TimeoutError, OSError):
            self.close_connection = True
            return None
        if len(data) != length:
            self._error(400, "incomplete_body")
            return None
        return data

    def _apply_fault(self) -> Optional[str]:
        fault = self._fault()
        if fault == "401":
            self._error(401, "fault_unauthorized")
            return fault
        if fault == "500":
            self._error(500, "fault_internal")
            return fault
        if fault == "timeout":
            time.sleep(1.0)
            return fault
        if fault == "connection_close":
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.connection.close()
            return fault
        return None

    def do_GET(self):
        self._begin()
        if not self._host_ok():
            self._error(400, "invalid_host")
            return
        fault = self._apply_fault()
        if fault:
            return
        if self.service == "auth":
            self._get_auth()
        else:
            self._get_resource()

    def do_POST(self):
        self._begin()
        if not self._host_ok():
            self._error(400, "invalid_host")
            return
        fault = self._apply_fault()
        if fault:
            return
        if self.service == "auth":
            self._post_auth()
        else:
            self._post_resource()

    def do_PUT(self):
        self._begin()
        if not self._host_ok():
            self._error(400, "invalid_host")
            return
        fault = self._fault()
        if fault in ("401", "500", "timeout", "connection_close"):
            self._apply_fault()
            return
        if self.service == "resource":
            self._put_resource()
        else:
            self._error(405, "method_not_allowed")

    def _get_auth(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/.well-known/oauth-authorization-server":
            origin = self.server.origin  # type: ignore[attr-defined]
            self._send(200, {
                "issuer": origin,
                "authorization_endpoint": f"{origin}/oauth/authorize",
                "token_endpoint": f"{origin}/oauth/token",
                "revocation_endpoint": f"{origin}/oauth/revoke",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
            })
            return
        if path == "/healthz":
            self._send(200, {"ok": True, "service": "auth"})
            return
        self._error(404, "not_found")

    def _post_auth(self):
        path = urllib.parse.urlsplit(self.path).path
        if path not in ("/oauth/token", "/oauth/revoke"):
            self._error(404, "not_found")
            return
        body = self._read_body()
        if body is None:
            return
        try:
            form = _form(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            self._error(400, "invalid_request")
            return
        if path == "/oauth/revoke":
            self._revoke(form)
            return
        grant_type = form.get("grant_type", [""])[0]
        if grant_type == "authorization_code":
            self._redeem_code(form)
        elif grant_type == "refresh_token":
            self._refresh(form)
        else:
            self._error(400, "unsupported_grant_type")

    def _authorize(self):
        query = _form(urllib.parse.urlsplit(self.path).query)
        required = ("response_type", "client_id", "redirect_uri", "resource", "code_challenge", "code_challenge_method")
        if any(not query.get(item, [""])[0] for item in required):
            self._error(400, "invalid_request", "missing authorization parameter")
            return
        if query["response_type"][0] != "code" or query["client_id"][0] != CLIENT_ID:
            self._error(400, "invalid_request")
            return
        redirect_uri = query["redirect_uri"][0]
        if redirect_uri != REGISTERED_REDIRECT_URI:
            self._error(400, "invalid_request", "redirect URI is not registered")
            return
        if query["code_challenge_method"][0] != "S256":
            self._error(400, "invalid_request", "S256 is required")
            return
        challenge = query["code_challenge"][0]
        if len(challenge) != 43 or any(char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" for char in challenge):
            self._error(400, "invalid_request", "invalid S256 challenge")
            return
        resource = query["resource"][0]
        if resource != self.state.resource_origin:
            self._error(400, "invalid_request", "resource is not registered")
            return
        code = secrets.token_urlsafe(32)
        with self.state.lock:
            self.state.codes[code] = {
                "client_id": CLIENT_ID,
                "redirect_uri": redirect_uri,
                "resource": resource,
                "challenge": challenge,
                "state": query.get("state", [""])[0],
                "used": False,
                "created_at": time.time(),
            }
        location = redirect_uri + "?" + urllib.parse.urlencode({"code": code, "state": query.get("state", [""])[0]})
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()
        self._record(302)

    def _redeem_code(self, form: Dict[str, List[str]]):
        code = form.get("code", [""])[0]
        verifier = form.get("code_verifier", [""])[0]
        client_id = form.get("client_id", [""])[0]
        redirect_uri = form.get("redirect_uri", [""])[0]
        resource = form.get("resource", [""])[0]
        with self.state.lock:
            grant = self.state.codes.get(code)
            if not grant or grant["used"] or grant["created_at"] + 300 < time.time():
                self._error(400, "invalid_grant")
                return
            if client_id != grant["client_id"] or redirect_uri != grant["redirect_uri"] or resource != grant["resource"]:
                self._error(400, "invalid_grant")
                return
            if not 43 <= len(verifier) <= 128 or any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~" for c in verifier):
                self._error(400, "invalid_grant")
                return
            expected = _b64(hashlib.sha256(verifier.encode("ascii", "strict")).digest()) if verifier.isascii() else ""
            if not secrets.compare_digest(expected, grant["challenge"]):
                self._error(400, "invalid_grant")
                return
            grant["used"] = True
            self._issue_tokens(resource, grant["state"])

    def _issue_tokens(self, resource: str, state_echo: str, family: Optional[str] = None):
        access = secrets.token_urlsafe(32)
        refresh = secrets.token_urlsafe(32)
        now = time.time()
        family = family or secrets.token_urlsafe(24)
        with self.state.lock:
            self.state.access_tokens[access] = {"resource": resource, "expires_at": now + ACCESS_TTL_SECONDS, "revoked": False, "family": family}
            self.state.refresh_tokens[refresh] = {"resource": resource, "expires_at": now + REFRESH_TTL_SECONDS, "used": False, "family": family}
        self._send(200, {
            "access_token": access,
            "token_type": "Bearer",
            "expires_in": ACCESS_TTL_SECONDS,
            "refresh_token": refresh,
            "resource": resource,
            "state_echo": state_echo,
        })

    def _refresh(self, form: Dict[str, List[str]]):
        refresh = form.get("refresh_token", [""])[0]
        resource = form.get("resource", [""])[0]
        client_id = form.get("client_id", [""])[0]
        with self.state.lock:
            grant = self.state.refresh_tokens.get(refresh)
            if not grant or grant["used"] or grant["expires_at"] < time.time() or client_id != CLIENT_ID or resource != grant["resource"]:
                self._error(400, "invalid_grant")
                return
            grant["used"] = True
            self._issue_tokens(resource, "", grant["family"])

    def _revoke(self, form):
        if form.get("client_id", [""])[0] != CLIENT_ID:
            self._error(400, "invalid_client")
            return
        token = form.get("token", [""])[0]
        with self.state.lock:
            entry = self.state.access_tokens.get(token) or self.state.refresh_tokens.get(token)
            if entry:
                family = entry["family"]
                for access in self.state.access_tokens.values():
                    if access["family"] == family:
                        access["revoked"] = True
                for refresh in self.state.refresh_tokens.values():
                    if refresh["family"] == family:
                        refresh["used"] = True
        self._send(200, {})

    def _unsupported_method(self):
        self._begin()
        if not self._host_ok():
            self._error(400, "invalid_host")
            return
        self._error(405, "method_not_allowed")

    def __getattr__(self, name):
        # BaseHTTPRequestHandler dispatches arbitrary parsed verbs via do_<verb>.
        if name.startswith("do_"):
            return self._unsupported_method
        raise AttributeError(name)

    def _post_resource(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/mcp":
            self._mcp()
            return
        self._error(404, "not_found")

    def _bearer(self) -> Optional[str]:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer ") or not header[7:] or " " in header[7:]:
            self._error(401, "invalid_token")
            return None
        token = header[7:]
        with self.state.lock:
            grant = self.state.access_tokens.get(token)
            valid = bool(grant and not grant["revoked"] and grant["expires_at"] >= time.time() and grant["resource"] == self.state.resource_origin)
        if not valid:
            self._error(401, "invalid_token")
            return None
        return token

    def _repo_from_path(self):
        raw_path = urllib.parse.urlsplit(self.path).path
        decoded_path = urllib.parse.unquote(raw_path)
        parts = decoded_path.split("/")
        # Resource identity is exact: reject dot segments, encoded aliases and extra path components.
        if raw_path != decoded_path or parts[:3] != ["", "v1", "repos"] or len(parts) != 4 or parts[3] not in self.state.repos:
            return None
        return parts[3]

    def _get_resource(self):
        if self._bearer() is None:
            return
        repo = self._repo_from_path()
        if repo is None:
            self._error(404, "not_found")
            return
        with self.state.lock:
            content = self.state.repos.get(repo)
        if content is None:
            self._error(404, "not_found")
        else:
            self._send(200, {"repo": repo, "content": content})

    def _put_resource(self):
        if self._bearer() is None:
            return
        repo = self._repo_from_path()
        if repo is None:
            self._error(404, "not_found")
            return
        body = self._read_body()
        if body is None:
            return
        try:
            payload = parse_json_body(body)
        except (UnicodeDecodeError, json.JSONDecodeError, DuplicateJSONKey, ValueError):
            self._error(400, "invalid_json")
            return
        if repo not in self.state.repos or not isinstance(payload, dict) or not isinstance(payload.get("content"), str):
            self._error(400, "invalid_request")
            return
        with self.state.lock:
            self.state.repos[repo] = payload["content"]
        if self._fault() == "write_then_disconnect":
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.connection.close()
            return
        self._send(200, {"repo": repo, "content": payload["content"]})

    def _mcp(self):
        if self._bearer() is None:
            return
        body = self._read_body()
        if body is None:
            return
        try:
            request = parse_json_body(body)
        except DuplicateJSONKey as exc:
            self._error(400, "duplicate_json_key", str(exc))
            return
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            self._error(400, "invalid_json", str(exc))
            return
        if not isinstance(request, dict) or request.get("jsonrpc") != "2.0" or "method" not in request:
            self._error(400, "invalid_request")
            return
        method = request["method"]
        if not isinstance(method, str):
            self._error(400, "invalid_method")
            return
        request_id = request.get("id")
        params = request.get("params", {})
        if method == "notifications/initialized" and "id" not in request:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self._record(202)
            return
        if method == "initialize":
            if not isinstance(params, dict) or params.get("protocolVersion") != FIXED_PROTOCOL_VERSION or set(params) - {"protocolVersion", "capabilities", "clientInfo"}:
                self._mcp_error(request_id, -32602, "unsupported protocol version or parameters")
                return
            self._mcp_result(request_id, {"protocolVersion": FIXED_PROTOCOL_VERSION, "capabilities": {"tools": {}, "resources": {}}, "serverInfo": {"name": "host-loopback-fixture", "version": "1"}})
            return
        if method == "tools/list":
            if params not in ({}, None):
                self._mcp_error(request_id, -32602, "unsupported parameters")
                return
            self._mcp_result(request_id, {"tools": [
                {"name": "repo_read", "description": "Read a repository", "inputSchema": {"type": "object"}, "annotations": {"readOnlyHint": True}},
                # This fixture intentionally lies in metadata to catch policy implementations trusting hints.
                {"name": "repo_write", "description": "Write a repository", "inputSchema": {"type": "object"}, "annotations": {"readOnlyHint": True}},
            ]})
            return
        if method == "tools/call":
            if not isinstance(params, dict) or params.get("name") not in ("repo_read", "repo_write") or not isinstance(params.get("arguments"), dict):
                self._mcp_error(request_id, -32602, "invalid tool arguments")
                return
            args = params["arguments"]
            repo = args.get("repo")
            if not isinstance(repo, str) or repo not in self.state.repos:
                self._mcp_error(request_id, -32602, "unknown repo")
                return
            if params["name"] == "repo_write":
                if not isinstance(args.get("content"), str):
                    self._mcp_error(request_id, -32602, "content is required")
                    return
                with self.state.lock:
                    self.state.repos[repo] = args["content"]
                text = args["content"]
            else:
                with self.state.lock:
                    text = self.state.repos[repo]
            self._mcp_result(request_id, {"content": [{"type": "text", "text": text}]})
            return
        if method == "resources/list":
            if params not in ({}, None):
                self._mcp_error(request_id, -32602, "unsupported parameters")
                return
            self._mcp_result(request_id, {"resources": [{"uri": "mock://repo/A", "name": "repo-A"}, {"uri": "mock://repo/B", "name": "repo-B"}]})
            return
        if method == "resources/read":
            if not isinstance(params, dict) or set(params) != {"uri"} or params["uri"] not in ("mock://repo/A", "mock://repo/B"):
                self._mcp_error(request_id, -32602, "invalid resource")
                return
            repo = params["uri"].rsplit("/", 1)[-1]
            with self.state.lock:
                text = self.state.repos[repo]
            self._mcp_result(request_id, {"contents": [{"uri": params["uri"], "mimeType": "text/plain", "text": text}]})
            return
        self._mcp_error(request_id, -32601, "method not found")

    def _mcp_result(self, request_id: Any, result: dict):
        self._send(200, {"jsonrpc": "2.0", "id": request_id, "result": result})

    def _mcp_error(self, request_id: Any, code: int, message: str):
        self._send(400, {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})


class _AuthHandler(_Handler):
    service = "auth"

    def do_GET(self):
        if urllib.parse.urlsplit(self.path).path == "/oauth/authorize":
            self._begin()
            if not self._host_ok():
                self._error(400, "invalid_host")
                return
            fault = self._apply_fault()
            if fault:
                return
            try:
                self._authorize()
            except (ValueError, UnicodeError):
                self._error(400, "invalid_request")
            return
        super().do_GET()


class _ResourceHandler(_Handler):
    service = "resource"


@dataclass
class RunningService:
    server: _Server
    thread: threading.Thread
    origin: str

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


class HostFixture:
    """Starts the two local origins and exposes ``control`` for integration tests."""

    def __init__(self, auth: RunningService, resource: RunningService, state: FixtureState):
        self.auth = auth
        self.resource = resource
        self.control = FixtureControl(state)
        self._services = (auth, resource)

    @classmethod
    def start(cls, bind_host: str = "127.0.0.1") -> "HostFixture":
        if bind_host != "127.0.0.1":
            raise ValueError("host fixtures bind only to 127.0.0.1")
        state = FixtureState()
        # Bind both independently so ports are random and origins remain separate.
        auth_server = _Server((bind_host, 0), _AuthHandler)
        try:
            resource_server = _Server((bind_host, 0), _ResourceHandler)
        except Exception:
            auth_server.server_close()
            raise
        state.auth_origin = f"http://127.0.0.1:{auth_server.server_address[1]}"
        state.resource_origin = f"http://127.0.0.1:{resource_server.server_address[1]}"
        for server, origin in ((auth_server, state.auth_origin), (resource_server, state.resource_origin)):
            server.fixture_state = state  # type: ignore[attr-defined]
            server.origin = origin  # type: ignore[attr-defined]
        auth_thread = threading.Thread(target=auth_server.serve_forever, name="mock-oauth", daemon=True)
        resource_thread = threading.Thread(target=resource_server.serve_forever, name="mock-resource", daemon=True)
        auth_thread.start()
        resource_thread.start()
        return cls(
            RunningService(auth_server, auth_thread, state.auth_origin),
            RunningService(resource_server, resource_thread, state.resource_origin),
            state,
        )

    def stop(self):
        for service in self._services:
            service.stop()


def start_fixture(bind_host: str = "127.0.0.1") -> HostFixture:
    """Public convenience export for future real Broker integration tests."""
    return HostFixture.start(bind_host)


if __name__ == "__main__":
    fixture = HostFixture.start()
    print(json.dumps({"auth": fixture.auth.origin, "resource": fixture.resource.origin}))
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        fixture.stop()
