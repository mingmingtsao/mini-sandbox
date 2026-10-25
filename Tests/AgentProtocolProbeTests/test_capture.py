import importlib.util
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('capture', ROOT / 'Tools/AgentProtocolProbe/capture.py')
assert spec is not None and spec.loader is not None
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class ShapeTests(unittest.TestCase):
    def test_bounded_shape_never_retains_values(self):
        body = b'{"model":"secret-canary","messages":[{"content":"secret-canary"}],"stream":true,"secret-canary":1}'
        shape = capture.inspect_json(body)
        self.assertEqual(shape.get('fields'), {'model': 'string', 'messages': 'array', 'stream': 'boolean'})
        self.assertEqual(shape['unknown_field_count'], 1)
        self.assertEqual(shape['message_count'], 1)
        self.assertNotIn('secret-canary', json.dumps(shape))

    def test_duplicate_and_wrong_shape_rejected(self):
        for body in (b'{"model":1,"model":2}', b'{"tools":{}}', b'[]', b'{"x":NaN}', b'{"x":{"a":1,"a":2}}'):
            with self.subTest(body=body):
                with self.assertRaises(ValueError):
                    capture.inspect_json(body)


import socket
import threading


def request(body=b'{}', headers=b'', path=b'/v1/messages', method=b'POST'):
    return (
        method
        + b' '
        + path
        + b' HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: '
        + str(len(body)).encode()
        + b'\r\n'
        + headers
        + b'\r\n'
        + body
    )


class TCPFixture(unittest.TestCase):
    def setUp(self):
        self.assertTrue(hasattr(capture, 'CaptureServer'), 'real TCP capture server missing')
        self.server = capture.CaptureServer(('127.0.0.1', 0))
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.01})
        self.thread.start()

    def tearDown(self):
        if hasattr(self, 'server'):
            self.server.shutdown()
            self.server.server_close()
            self.thread.join(2)

    def exchange(self, wire):
        with socket.create_connection(self.server.server_address, timeout=2) as s:
            s.sendall(wire)
            s.shutdown(socket.SHUT_WR)
            result = b''
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                result += chunk
            return result


class TCPTests(TCPFixture):
    def test_real_tcp_static_503_metadata_only(self):
        result = self.exchange(
            request(
                b'{"model":"canary-secret","messages":[{"content":"canary-secret"}],"stream":true}',
                b'Authorization: Bearer canary-secret\r\n',
            )
        )
        self.assertIn(b'503', result)
        self.assertEqual(len(self.server.records), 1)
        self.assertEqual(self.server.records[0]['shape']['message_count'], 1)
        self.assertNotIn('canary-secret', json.dumps(self.server.records))
        self.assertNotIn(b'canary-secret', result)

    def test_real_tcp_duplicate_framing_invalid_paths(self):
        bad = [
            request(headers=b'content-length: 2\r\n'),
            request(headers=b'Transfer-Encoding: chunked\r\n'),
            request(headers=b'X-A: x\r\nx-a: y\r\n'),
            request(path=b'/secret-canary'),
            request(method=b'GET'),
            request(headers=b' bad: folding\r\n'),
            request(b'{"x":1,"x":2}'),
            request(headers=b'Content-Encoding: gzip\r\n'),
            request(headers=b'Expect: 100-continue\r\n'),
            request() + b'GET /secret-canary HTTP/1.1\r\n\r\n',
        ]
        for wire in bad:
            self.assertIn(b'400', self.exchange(wire))
        self.assertNotIn('secret-canary', json.dumps(self.server.records))

    def test_oversize_header_and_body(self):
        for wire in (
            b'POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-Length: 1048577\r\n\r\n',
            b'POST /v1/messages HTTP/1.1\r\nX: ' + b'a' * 9000 + b'\r\n\r\n',
        ):
            self.assertIn(b'413', self.exchange(wire))

    def test_fixture_can_measure_over_64k_not_compatibility(self):
        body = json.dumps({'messages': [{'content': 'x' * 70000}]}).encode()
        self.assertIn(b'503', self.exchange(request(body)))
        self.assertEqual(self.server.records[0]['body_bytes'], len(body))
        self.assertGreater(self.server.records[0]['body_bytes'], 65536)

    def test_aggregate_and_connection_caps(self):
        self.server.max_wire = 20
        self.assertIn(b'429', self.exchange(request()))
        self.assertEqual(self.server.wire_bytes, 20)
        self.server.max_wire = 4194304
        self.server.max_connections = 1
        self.assertIn(b'429', self.exchange(request()))


class DeadlineTests(TCPFixture):
    def setUp(self):
        super().setUp()
        self.now = 100.0
        self.server.clock = lambda: self.now
        self.server.lifetime_deadline = 135.0

    def test_expired_capture_starts_no_ingress(self):
        self.server.lifetime_deadline = self.now
        self.assertIn(b'408', self.exchange(request()))
        self.assertEqual(self.server.wire_bytes, 0)
        self.assertEqual(self.server.records, [{'status': 408}])

    def test_body_crossing_capture_lifetime_is_not_accepted(self):
        self.assert_body_expiry(100.25)

    def test_body_crossing_absolute_ingress_deadline_is_not_accepted(self):
        self.assert_body_expiry(103.0)

    def assert_body_expiry(self, expiry):
        from unittest.mock import patch

        original = capture.CaptureHandler.receive
        self.server.lifetime_deadline = expiry if expiry < 103 else 135.0

        def receive(handler, count):
            chunk = original(handler, count)
            if count > 1:
                self.now = expiry
            return chunk

        with patch.object(capture.CaptureHandler, 'receive', receive):
            self.assertIn(b'408', self.exchange(request()))
        self.assertEqual(self.server.records, [{'status': 408}])

    def test_parse_crossing_lifetime_drops_accepted_metadata(self):
        self.assert_parse_expiry(135.0)

    def test_parse_crossing_ingress_deadline_drops_accepted_metadata(self):
        self.assert_parse_expiry(103.0)

    def assert_parse_expiry(self, expiry):
        from unittest.mock import patch

        entered, release = threading.Event(), threading.Event()
        original = capture.inspect_json

        def parse(body):
            result = original(body)
            entered.set()
            if not release.wait(2):
                raise ValueError('barrier_timeout')
            return result

        with patch.object(capture, 'inspect_json', parse):
            with socket.create_connection(self.server.server_address, timeout=2) as client:
                client.sendall(request())
                client.shutdown(socket.SHUT_WR)
                try:
                    self.assertTrue(entered.wait(2))
                    self.now = expiry
                finally:
                    release.set()
                response = b''
                while True:
                    chunk = client.recv(4096)
                    if not chunk:
                        break
                    response += chunk
                self.assertIn(b'408', response)
        self.assertEqual(self.server.records, [{'status': 408}])

    def test_remaining_lifetime_caps_reads_and_response(self):
        from unittest.mock import patch

        timeouts = []

        class ObservedSocket:
            def __init__(self, sock):
                self.sock = sock

            def __getattr__(self, name):
                return getattr(self.sock, name)

            def settimeout(self, timeout):
                timeouts.append(timeout)
                self.sock.settimeout(timeout)

        def setup(handler):
            handler.request = ObservedSocket(handler.request)

        self.server.lifetime_deadline = 100.25
        with patch.object(capture.CaptureHandler, 'setup', setup):
            self.assertIn(b'503', self.exchange(request()))
        self.assertTrue(timeouts)
        self.assertTrue(all(0 < value <= 0.25 for value in timeouts), timeouts)

    def test_expiry_during_response_does_not_retain_accepted_metadata(self):
        from unittest.mock import patch

        class ExpiringSocket:
            def __init__(inner, sock):
                inner.sock = sock

            def __getattr__(inner, name):
                return getattr(inner.sock, name)

            def sendall(inner, data):
                self.now = self.server.lifetime_deadline
                raise socket.timeout()

        def setup(handler):
            handler.request = ExpiringSocket(handler.request)

        with patch.object(capture.CaptureHandler, 'setup', setup):
            self.assertEqual(self.exchange(request()), b'')
        self.assertEqual(self.server.records, [{'status': 408}])


class BoundaryTests(TCPFixture):
    def test_exact_body_and_aggregate_limits_accept_last_byte(self):
        body = b'{' + b' ' * (capture.BODY_CAP - 2) + b'}'
        wire = request(body)
        self.server.max_wire = len(wire)
        self.assertIn(b'503', self.exchange(wire))
        self.assertEqual(self.server.wire_bytes, len(wire))
        self.assertEqual(self.server.records[0]['body_bytes'], capture.BODY_CAP)
        self.assertIn(b'429', self.exchange(request()))
        self.assertEqual(self.server.wire_bytes, len(wire))

    def test_truncated_body_is_static_failure(self):
        self.assertIn(b'400', self.exchange(request(b'{"x":1}')[:-1]))
        self.assertEqual(self.server.records, [{'status': 400}])

    def test_slow_partial_body_times_out_without_more_input(self):
        # The client never sends the final byte: no sleep-based ordering.
        self.server.request_deadline = 0.05
        with socket.create_connection(self.server.server_address, timeout=2) as client:
            client.sendall(request(b'{}')[:-1])
            self.assertIn(b'408', client.recv(4096))
        self.assertEqual(self.server.records, [{'status': 408}])

    def test_populated_capture_stderr_and_output_privacy(self):
        import contextlib
        import io
        from unittest.mock import patch

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            result = self.exchange(
                request(
                    b'{"model":"RAW_PROMPT_CANARY","TOKEN_UNKNOWN_CANARY":"RAW_TOKEN_CANARY"}',
                    b'Authorization: Bearer RAW_TOKEN_CANARY\r\n',
                )
            )
            self.assertIn(b'503', result)
            self.assertIn(b'400', self.exchange(request(b'{"RAW_PROMPT_CANARY":')))
            with patch.object(capture, 'inspect_json', side_effect=RuntimeError('RAW_TOKEN_CANARY')):
                self.assertEqual(self.exchange(request()), b'')
        self.assertEqual(stderr.getvalue(), '')
        saved = json.dumps(self.server.records) + result.decode()
        for marker in ('RAW_PROMPT_CANARY', 'RAW_TOKEN_CANARY', 'TOKEN_UNKNOWN_CANARY', 'Traceback'):
            self.assertNotIn(marker, saved)
        self.assertEqual(self.server.records[0]['shape']['unknown_field_count'], 1)


if __name__ == '__main__':
    unittest.main()
