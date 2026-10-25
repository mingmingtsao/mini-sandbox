import base64
import hashlib
import http.client
import json
import socket
import unittest
from unittest.mock import patch
import urllib.error
import urllib.parse
import urllib.request

from host_services import (
    FIXED_PROTOCOL_VERSION,
    MAX_BODY_BYTES,
    HostFixture,
    parse_json_body,
)


CLIENT_ID = "fixture-client"
REDIRECT_URI = "http://127.0.0.1/callback"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


NO_REDIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)


def request(url, method="GET", data=None, headers=None, timeout=1.0):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with NO_REDIRECT_OPENER.open(req, timeout=timeout) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), exc.read()


def json_request(url, method="GET", payload=None, token=None, timeout=1.0):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if payload is None else json.dumps(payload).encode()
    return request(url, method, data, headers, timeout)


def raw_exchange(origin, wire):
    address = urllib.parse.urlsplit(origin)
    with socket.create_connection((address.hostname, address.port), timeout=2) as connection:
        connection.sendall(wire)
        connection.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = connection.recv(65536)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)


def raw_request(origin, method, target, headers=None, body=b""):
    # Preserve the request target and inspect HEAD bytes without client suppression.
    if headers is None:
        headers = [("Host", urllib.parse.urlsplit(origin).netloc)]
    lines = [f"{method} {target} HTTP/1.1"]
    lines.extend(f"{key}: {value}" for key, value in headers)
    lines.extend(["Connection: close", f"Content-Length: {len(body)}", "", ""])
    response = raw_exchange(origin, "\r\n".join(lines).encode("ascii") + body)
    head, payload = response.split(b"\r\n\r\n", 1)
    return int(head.split(b" ", 2)[1]), payload


def decode(body):
    return json.loads(body.decode()) if body else None


class FixtureTests(unittest.TestCase):
    def test_numeric_loopback_startup_never_resolves_dns(self):
        with patch("socket.getfqdn", side_effect=AssertionError("fixture attempted DNS")):
            fixture = HostFixture.start()
            try:
                for service in (fixture.auth, fixture.resource):
                    self.assertEqual(service.server.server_name, "127.0.0.1")
                    self.assertGreater(service.server.server_port, 0)
                self.assertEqual(request(fixture.auth.origin + "/.well-known/oauth-authorization-server")[0], 200)
                self.assertEqual(request(fixture.resource.origin + "/mcp")[0], 401)
            finally:
                fixture.stop()

    @classmethod
    def setUpClass(cls):
        cls.fixture = HostFixture.start()
        cls.auth = cls.fixture.auth.origin
        cls.resource = cls.fixture.resource.origin
        cls.redirect_uri = REDIRECT_URI

    @classmethod
    def tearDownClass(cls):
        cls.fixture.stop()

    def setUp(self):
        self.fixture.control.reset()

    def authorize(self, verifier="v" * 43, redirect_uri=REDIRECT_URI, resource=None):
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        query = urllib.parse.urlencode(
            {
                "response_type": "code",
                "client_id": CLIENT_ID,
                "redirect_uri": redirect_uri,
                "resource": resource or self.resource,
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "state": "round-trip-state",
            }
        )
        return request(f"{self.auth}/oauth/authorize?{query}", timeout=1)

    def token(self, code, verifier="v" * 43, redirect_uri=REDIRECT_URI, resource=None):
        body = urllib.parse.urlencode(
            {
                "grant_type": "authorization_code",
                "code": code,
                "client_id": CLIENT_ID,
                "redirect_uri": redirect_uri,
                "code_verifier": verifier,
                "resource": resource or self.resource,
            }
        ).encode()
        return request(f"{self.auth}/oauth/token", "POST", body, {"Content-Type": "application/x-www-form-urlencoded"})

    def issue_token(self, verifier="v" * 43, resource=None):
        status, headers, _ = self.authorize(verifier=verifier, resource=resource)
        self.assertEqual(status, 302)
        location = headers["Location"]
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(location).query)
        self.assertEqual(query["state"], ["round-trip-state"])
        status, _, body = self.token(query["code"][0], verifier=verifier, resource=resource)
        self.assertEqual(status, 200, body)
        result = decode(body)
        self.assertIsInstance(result, dict)
        assert isinstance(result, dict)
        return result

    def test_metadata_and_separate_loopback_origins(self):
        self.assertNotEqual(self.auth, self.resource)
        self.assertTrue(self.auth.startswith("http://127.0.0.1:"))
        self.assertTrue(self.resource.startswith("http://127.0.0.1:"))
        status, _, body = request(f"{self.auth}/.well-known/oauth-authorization-server")
        self.assertEqual(status, 200)
        metadata = decode(body)
        self.assertEqual(metadata["issuer"], self.auth)
        self.assertEqual(metadata["authorization_endpoint"], f"{self.auth}/oauth/authorize")

    def test_oauth_pkce_state_and_code_binding(self):
        token = self.issue_token()
        self.assertTrue(token["access_token"])
        self.assertTrue(token["refresh_token"])
        self.assertEqual(token["resource"], self.resource)
        self.assertEqual(token["state_echo"], "round-trip-state")

        status, _, body = self.token("missing-code")
        self.assertEqual(status, 400)
        self.assertEqual(decode(body)["error"], "invalid_grant")

    def test_bad_pkce_reused_code_and_invalid_bindings(self):
        status, headers, _ = self.authorize()
        self.assertEqual(status, 302)
        code = urllib.parse.parse_qs(urllib.parse.urlsplit(headers["Location"]).query)["code"][0]
        status, _, body = self.token(code, verifier="x" * 43)
        self.assertEqual(status, 400)
        self.assertEqual(decode(body)["error"], "invalid_grant")

        status, headers, _ = self.authorize()
        code = urllib.parse.parse_qs(urllib.parse.urlsplit(headers["Location"]).query)["code"][0]
        status, _, _ = self.token(code, redirect_uri="http://127.0.0.1/other")
        self.assertEqual(status, 400)
        status, _, _ = self.token(code, resource="http://127.0.0.1:9")
        self.assertEqual(status, 400)

        status, _, body = self.token(code)
        self.assertEqual(status, 200)
        status, _, body = self.token(code)
        self.assertEqual(status, 400)
        self.assertEqual(decode(body)["error"], "invalid_grant")

    def test_authorize_rejects_redirect_and_token_rejects_verifier_bounds(self):
        status, _, body = self.authorize(redirect_uri="http://127.0.0.1/other")
        self.assertEqual(status, 400)
        self.assertEqual(decode(body)["error"], "invalid_request")
        for length in (42, 129):
            status, headers, _ = self.authorize()
            self.assertEqual(status, 302)
            code = urllib.parse.parse_qs(urllib.parse.urlsplit(headers["Location"]).query)["code"][0]
            status, _, body = self.token(code, verifier="v" * length)
            self.assertEqual(status, 400)
            self.assertEqual(decode(body)["error"], "invalid_grant")

    def test_expired_revoked_access_and_audience_are_rejected(self):
        issued = self.issue_token()
        token = issued["access_token"]
        status, _, _ = json_request(f"{self.resource}/v1/repos/A", token=token)
        self.assertEqual(status, 200)
        self.fixture.control.expire_access(token)
        status, _, _ = json_request(f"{self.resource}/v1/repos/A", token=token)
        self.assertEqual(status, 401)

        issued = self.issue_token()
        token = issued["access_token"]
        self.fixture.control.revoke(token)
        status, _, _ = json_request(f"{self.resource}/v1/repos/A", token=token)
        self.assertEqual(status, 401)

        status, headers, _ = self.authorize()
        code = urllib.parse.parse_qs(urllib.parse.urlsplit(headers["Location"]).query)["code"][0]
        issued_status, _, body = self.token(code, resource="http://127.0.0.1:9")
        self.assertEqual(issued_status, 400)
        self.assertEqual(decode(body)["error"], "invalid_grant")

        issued = self.issue_token()
        self.fixture.control.expire_access(issued["access_token"])
        status, _, _ = json_request(f"{self.resource}/v1/repos/A", token=issued["access_token"])
        self.assertEqual(status, 401)

    def test_refresh_rotation_is_single_use(self):
        issued = self.issue_token()
        body = urllib.parse.urlencode(
            {
                "grant_type": "refresh_token",
                "refresh_token": issued["refresh_token"],
                "client_id": CLIENT_ID,
                "resource": self.resource,
            }
        ).encode()
        status, _, response = request(
            f"{self.auth}/oauth/token", "POST", body, {"Content-Type": "application/x-www-form-urlencoded"}
        )
        self.assertEqual(status, 200)
        rotated = decode(response)
        self.assertNotEqual(rotated["refresh_token"], issued["refresh_token"])
        status, _, response = request(
            f"{self.auth}/oauth/token", "POST", body, {"Content-Type": "application/x-www-form-urlencoded"}
        )
        self.assertEqual(status, 400)
        self.assertEqual(decode(response)["error"], "invalid_grant")

    def test_resource_baseline_allows_both_repos_and_both_writes(self):
        token = self.issue_token()["access_token"]
        for repo in ("A", "B"):
            status, _, body = json_request(f"{self.resource}/v1/repos/{repo}", token=token)
            self.assertEqual(status, 200)
            self.assertEqual(decode(body)["repo"], repo)
            status, _, body = json_request(
                f"{self.resource}/v1/repos/{repo}", "PUT", {"content": f"baseline-{repo}"}, token
            )
            self.assertEqual(status, 200)
            self.assertEqual(decode(body)["content"], f"baseline-{repo}")
        self.assertEqual(self.fixture.control.resource_hit_count, 4)

    def test_mcp_fixed_protocol_tools_resources_and_write_hint_lies(self):
        token = self.issue_token()["access_token"]
        init = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": FIXED_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "test", "version": "1"},
            },
        }
        status, _, body = json_request(f"{self.resource}/mcp", "POST", init, token)
        self.assertEqual(status, 200)
        self.assertEqual(decode(body)["result"]["protocolVersion"], FIXED_PROTOCOL_VERSION)

        status, _, body = json_request(
            f"{self.resource}/mcp", "POST", {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, token
        )
        self.assertEqual(status, 200)
        tools = decode(body)["result"]["tools"]
        write_tool = next(tool for tool in tools if tool["name"] == "repo_write")
        self.assertTrue(write_tool["annotations"]["readOnlyHint"])

        status, _, body = json_request(
            f"{self.resource}/mcp",
            "POST",
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "repo_write", "arguments": {"repo": "A", "content": "mcp-write"}},
            },
            token,
        )
        self.assertEqual(status, 200)
        self.assertEqual(decode(body)["result"]["content"][0]["text"], "mcp-write")

        status, _, body = json_request(
            f"{self.resource}/mcp", "POST", {"jsonrpc": "2.0", "id": 4, "method": "resources/list", "params": {}}, token
        )
        self.assertEqual(status, 200)
        self.assertEqual(len(decode(body)["result"]["resources"]), 2)
        status, _, body = json_request(
            f"{self.resource}/mcp",
            "POST",
            {"jsonrpc": "2.0", "id": 5, "method": "resources/read", "params": {"uri": "mock://repo/A"}},
            token,
        )
        self.assertEqual(status, 200)
        self.assertEqual(decode(body)["result"]["contents"][0]["text"], "mcp-write")

    def test_mcp_initialized_errors_and_notifications(self):
        token = self.issue_token()["access_token"]
        status, _, _ = json_request(
            f"{self.resource}/mcp",
            "POST",
            {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
            token,
        )
        self.assertEqual(status, 202)
        for method in ("unknown/method", "tools/list"):
            payload = {"jsonrpc": "2.0", "id": 9, "method": method, "params": {}}
            if method == "tools/list":
                payload["params"] = {"unsupported": True}
            status, _, body = json_request(f"{self.resource}/mcp", "POST", payload, token)
            self.assertEqual(status, 400)
            self.assertEqual(decode(body)["error"]["code"], -32602 if method == "tools/list" else -32601)
        payload = {
            "jsonrpc": "2.0",
            "id": 10,
            "method": "initialize",
            "params": {"protocolVersion": "1999-01-01", "capabilities": {}, "clientInfo": {}},
        }
        status, _, body = json_request(f"{self.resource}/mcp", "POST", payload, token)
        self.assertEqual(status, 400)
        self.assertEqual(decode(body)["error"]["code"], -32602)

    def test_oversized_and_duplicate_json_are_rejected(self):
        token = self.issue_token()["access_token"]
        huge = b"{" + b"x" * MAX_BODY_BYTES + b"}"
        status, _, _ = request(
            f"{self.resource}/mcp",
            "POST",
            huge,
            {"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
        )
        self.assertEqual(status, 413)
        duplicate = b'{"jsonrpc":"2.0","id":1,"method":"tools/list","method":"tools/list"}'
        status, _, body = request(
            f"{self.resource}/mcp",
            "POST",
            duplicate,
            {"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
        )
        self.assertEqual(status, 400)
        self.assertIn("duplicate", decode(body)["error"].lower())
        with self.assertRaises(ValueError):
            parse_json_body(duplicate)

    def test_host_header_and_bind_policy(self):
        token = self.issue_token()["access_token"]
        status, _, _ = json_request(f"{self.resource}/v1/repos/A", token=token)
        self.assertEqual(status, 200)
        status, _, _ = request(f"{self.resource}/v1/repos/A", headers={"Host": "example.invalid"})
        self.assertEqual(status, 400)
        with self.assertRaises(ValueError):
            HostFixture.start(bind_host="0.0.0.0")

    def test_fault_toggles_and_write_then_disconnect_unknown_result(self):
        token = self.issue_token()["access_token"]
        for mode, expected in (("401", 401), ("500", 500)):
            self.fixture.control.set_fault("resource", mode)
            status, _, _ = json_request(f"{self.resource}/v1/repos/A", token=token)
            self.assertEqual(status, expected)
            self.fixture.control.clear_fault("resource")

        self.fixture.control.set_fault("resource", "write_then_disconnect")
        with self.assertRaises((http.client.RemoteDisconnected, ConnectionResetError, urllib.error.URLError)):
            json_request(f"{self.resource}/v1/repos/A", "PUT", {"content": "unknown-result"}, token, timeout=0.5)
        self.fixture.control.clear_fault("resource")
        status, _, body = json_request(f"{self.resource}/v1/repos/A", token=token)
        self.assertEqual(status, 200)
        self.assertEqual(decode(body)["content"], "unknown-result")
        self.fixture.control.set_fault("resource", "timeout")
        with self.assertRaises((TimeoutError, socket.timeout, urllib.error.URLError, http.client.RemoteDisconnected)):
            json_request(f"{self.resource}/v1/repos/A", token=token, timeout=0.1)

    def test_disconnect_is_counted_at_upstream_before_reply(self):
        token = self.issue_token()["access_token"]
        self.fixture.control.reset()
        self.fixture.control.set_fault("resource", "write_then_disconnect")
        with self.assertRaises((http.client.RemoteDisconnected, ConnectionResetError, urllib.error.URLError)):
            json_request(f"{self.resource}/v1/repos/B", "PUT", {"content": "executed"}, token)
        self.assertEqual(self.fixture.control.resource_hit_count, 1)
        self.assertEqual(self.fixture.control.transcripts()[0]["path"], "/v1/repos/B")

    def test_invalid_pkce_alphabet_and_duplicate_parameters_rejected(self):
        invalid = "!" * 43
        status, headers, _ = self.authorize(verifier=invalid)
        if status == 302:
            code = urllib.parse.parse_qs(urllib.parse.urlsplit(headers["Location"]).query)["code"][0]
            self.assertEqual(self.token(code, verifier=invalid)[0], 400)
        else:
            self.assertEqual(status, 400)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(b"v" * 43).digest()).rstrip(b"=").decode()
        query = urllib.parse.urlencode(
            {
                "response_type": "code",
                "client_id": CLIENT_ID,
                "redirect_uri": REDIRECT_URI,
                "resource": self.resource,
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "state": "x",
            }
        )
        self.assertEqual(request(f"{self.auth}/oauth/authorize?{query}&client_id=other")[0], 400)

    def test_arbitrary_unsupported_method_is_counted_once(self):
        status, _, body = request(f"{self.resource}/v1/repos/B", "BREW")
        self.assertEqual(self.fixture.control.resource_hit_count, 1)
        self.assertEqual(
            self.fixture.control.transcripts(),
            [
                {"service": "resource", "method": "BREW", "path": "/v1/repos/B", "status": 405},
            ],
        )
        self.assertEqual(status, 405)
        self.assertEqual(decode(body), {"error": "method_not_allowed"})

    def test_unsupported_methods_follow_exact_host_policy(self):
        for service, origin in (("auth", self.auth), ("resource", self.resource)):
            host = urllib.parse.urlsplit(origin).netloc
            for method in ("BREW", "PATCH", "HEAD"):
                for hosts, expected in (
                    ([host], 405),
                    ([], 400),
                    (["example.invalid"], 400),
                    ([host, host], 400),
                    ([host.replace("127.0.0.1", "localhost")], 400),
                ):
                    with self.subTest(service=service, method=method, hosts=hosts):
                        self.fixture.control.reset()
                        status, _ = raw_request(origin, method, "/v1/repos/B", [("Host", item) for item in hosts])
                        self.assertEqual(status, expected)
                        self.assertEqual(self.fixture.control.resource_hit_count, int(service == "resource"))
                        self.assertEqual(
                            self.fixture.control.transcripts(),
                            [
                                {"service": service, "method": method, "path": "/v1/repos/B", "status": expected},
                            ],
                        )

    def test_head_errors_have_no_wire_body(self):
        for origin in (self.auth, self.resource):
            for headers, expected in ((None, 405), ([("Host", "example.invalid")], 400)):
                with self.subTest(origin=origin, expected=expected):
                    status, body = raw_request(origin, "HEAD", "/v1/repos/B", headers)
                    self.assertEqual(status, expected)
                    self.assertEqual(body, b"")

    def test_resource_path_aliases_and_unsupported_methods_are_rejected_and_recorded(self):
        token = self.issue_token()["access_token"]
        self.fixture.control.reset()
        self.assertEqual(json_request(f"{self.resource}/v1/repos/../B", token=token)[0], 404)
        self.assertEqual(json_request(f"{self.resource}/v1/repos/%2e%2e/B", token=token)[0], 404)
        status, _, _ = request(f"{self.resource}/v1/repos/B", "PATCH", headers={"Authorization": f"Bearer {token}"})
        self.assertEqual(status, 405)
        self.assertEqual(self.fixture.control.resource_hit_count, 3)
        self.assertEqual(len(self.fixture.control.transcripts()), 3)

    def test_raw_resource_path_aliases_rejected_without_repo_changes(self):
        token = self.issue_token()["access_token"]
        headers = [("Host", urllib.parse.urlsplit(self.resource).netloc), ("Authorization", f"Bearer {token}")]
        before = {repo: decode(json_request(f"{self.resource}/v1/repos/{repo}", token=token)[2]) for repo in ("A", "B")}
        aliases = ("/v1/repos/../B", "/v1/repos/%2e%2e/B", "/v1/repos/%42", "/v1/repos/./B")
        for method in ("GET", "PUT"):
            for target in aliases:
                with self.subTest(method=method, target=target):
                    self.fixture.control.reset()
                    status, _ = raw_request(self.resource, method, target, headers, b'{"content":"must-not-write"}')
                    self.assertEqual(status, 404)
                    self.assertEqual(self.fixture.control.resource_hit_count, 1)
                    self.assertEqual(
                        self.fixture.control.transcripts(),
                        [
                            {"service": "resource", "method": method, "path": target, "status": 404},
                        ],
                    )
                    for repo in ("A", "B"):
                        status, _, body = json_request(f"{self.resource}/v1/repos/{repo}", token=token)
                        self.assertEqual(status, 200)
                        self.assertEqual(decode(body), before[repo])

    def test_direct_bearer_with_mismatched_audience_is_rejected(self):
        token = self.issue_token()["access_token"]
        state = self.fixture.resource.server.fixture_state  # type: ignore[attr-defined]
        with state.lock:
            state.access_tokens[token]["resource"] = self.auth
        self.fixture.control.reset()
        status, _, body = json_request(f"{self.resource}/v1/repos/A", token=token)
        self.assertEqual(status, 401)
        self.assertEqual(decode(body), {"error": "invalid_token"})
        self.assertEqual(self.fixture.control.resource_hit_count, 1)

    def test_counter_scope_parsed_requests_not_malformed_tcp(self):
        response = raw_exchange(self.resource, b"GET / extra HTTP/1.1\r\n\r\n")
        self.assertIn(b" 400 ", response.split(b"\r\n", 1)[0])
        self.assertEqual(self.fixture.control.resource_hit_count, 0)
        self.assertEqual(self.fixture.control.transcripts(), [])
        token = self.issue_token()["access_token"]
        self.fixture.control.reset()
        status, _, body = request(f"{self.resource}/mcp", "POST", b"{", {"Authorization": f"Bearer {token}"})
        self.assertEqual(status, 400)
        payload = decode(body)
        assert isinstance(payload, dict)
        self.assertEqual(payload["error"], "invalid_json")
        self.assertEqual(self.fixture.control.resource_hit_count, 1)
        self.assertEqual(
            self.fixture.control.transcripts(),
            [
                {"service": "resource", "method": "POST", "path": "/mcp", "status": 400},
            ],
        )

    def test_http_revocation_blocks_access_and_refresh(self):
        issued = self.issue_token()
        body = urllib.parse.urlencode(
            {"token": issued["refresh_token"], "token_type_hint": "refresh_token", "client_id": CLIENT_ID}
        ).encode()
        self.assertEqual(
            request(f"{self.auth}/oauth/revoke", "POST", body, {"Content-Type": "application/x-www-form-urlencoded"})[
                0
            ],
            200,
        )
        self.assertEqual(json_request(f"{self.resource}/v1/repos/A", token=issued["access_token"])[0], 401)
        refresh = urllib.parse.urlencode(
            {
                "grant_type": "refresh_token",
                "refresh_token": issued["refresh_token"],
                "client_id": CLIENT_ID,
                "resource": self.resource,
            }
        ).encode()
        self.assertEqual(
            request(f"{self.auth}/oauth/token", "POST", refresh, {"Content-Type": "application/x-www-form-urlencoded"})[
                0
            ],
            400,
        )

    def test_transcripts_redact_tokens_and_request_bodies_and_reset(self):
        token = self.issue_token()["access_token"]
        secret_body = "do-not-log-this-body"
        secret_query = "do-not-log-this-query"
        status, _, _ = json_request(
            f"{self.resource}/v1/repos/A?secret={secret_query}", "PUT", {"content": secret_body}, token
        )
        self.assertEqual(status, 200)
        transcript = repr(self.fixture.control.transcripts())
        self.assertNotIn(token, transcript)
        self.assertNotIn(secret_body, transcript)
        self.assertNotIn(secret_query, transcript)
        self.assertGreater(self.fixture.control.resource_hit_count, 0)
        self.fixture.control.reset()
        self.assertEqual(self.fixture.control.resource_hit_count, 0)
        self.assertEqual(self.fixture.control.transcripts(), [])


if __name__ == "__main__":
    unittest.main()
