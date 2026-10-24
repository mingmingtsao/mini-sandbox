"""Bounded, metadata-only protocol capture; never a model emulator."""

import json
import re
import socket
import socketserver
import time

BODY_CAP = 1048576
HEADER_CAP = 8192
FRAME_CAP = 4096
PATHS = {b'/v1/messages': 'messages', b'/v1/messages?beta=true': 'messages_beta',
         b'/v1/messages/count_tokens': 'count_tokens',
         b'/v1/messages/count_tokens?beta=true': 'count_tokens_beta'}


class Rejected(Exception):
    def __init__(self, status):
        self.status = status


class CaptureServer(socketserver.TCPServer):
    allow_reuse_address = False
    request_queue_size = 4

    def __init__(self, address=('127.0.0.1', 4061), *, lifetime=35.0, clock=None):
        if address[0] != '127.0.0.1':
            raise ValueError('loopback_only')
        self.records = []
        self.wire_bytes = 0
        self.connections = 0
        self.max_wire = 4194304
        self.max_connections = 16
        self.request_deadline = 3.0
        self.clock = clock or time.monotonic
        self.lifetime_deadline = self.clock() + lifetime
        super().__init__(address, CaptureHandler)

    def handle_error(self, request, client_address):
        # No request details, paths, exceptions, or traceback in diagnostics.
        pass


class CaptureHandler(socketserver.BaseRequestHandler):
    server: CaptureServer

    def remaining_ingress(self):
        remaining = min(self.deadline, self.server.lifetime_deadline) - self.server.clock()
        if remaining <= 0:
            raise Rejected(408)
        return remaining

    def receive(self, count):
        remaining = self.remaining_ingress()
        budget = self.server.max_wire - self.server.wire_bytes
        if budget <= 0:
            raise Rejected(429)
        self.request.settimeout(remaining)
        chunk = self.request.recv(min(count, FRAME_CAP, budget))
        self.server.wire_bytes += len(chunk)
        self.remaining_ingress()
        if not chunk:
            raise Rejected(400)
        return chunk

    def handle(self):
        status, record = 400, {'status': 400}
        self.deadline = min(self.server.clock() + self.server.request_deadline,
                            self.server.lifetime_deadline)
        self.server.connections += 1
        try:
            self.remaining_ingress()
            if self.server.connections > self.server.max_connections:
                raise Rejected(429)
            header = bytearray()
            # Read the header without consuming an unbounded body or pipeline.
            while not header.endswith(b'\r\n\r\n'):
                if len(header) >= HEADER_CAP:
                    raise Rejected(413)
                header.extend(self.receive(1))
            lines = bytes(header[:-4]).split(b'\r\n')
            start = lines.pop(0).split(b' ')
            if len(start) != 3 or start[0] != b'POST' or start[1] not in PATHS or start[2] != b'HTTP/1.1':
                raise Rejected(400)
            headers = {}
            if len(lines) > 64:
                raise Rejected(413)
            for line in lines:
                key, sep, val = line.partition(b':')
                if not sep or not re.fullmatch(rb'[!#$%&\x27*+.^_`|~0-9A-Za-z-]+', key):
                    raise Rejected(400)
                key = key.lower()
                if key in headers or any(c < 32 and c != 9 or c == 127 for c in val):
                    raise Rejected(400)
                headers[key] = val.strip(b' \t')
            if any(k in headers for k in (b'transfer-encoding', b'content-encoding', b'expect')):
                raise Rejected(400)
            length = headers.get(b'content-length', b'')
            if not re.fullmatch(rb'0|[1-9][0-9]{0,9}', length):
                raise Rejected(400)
            size = int(length)
            if size > BODY_CAP:
                raise Rejected(413)
            host = headers.get(b'host', b'')
            allowed_host = (b'127.0.0.1', ('127.0.0.1:%d' % self.server.server_address[1]).encode())
            if host not in allowed_host or headers.get(b'content-type') not in (b'application/json', b'application/json; charset=utf-8'):
                raise Rejected(400)
            body = bytearray()
            frames = 0
            while len(body) < size:
                body.extend(self.receive(size - len(body)))
                frames += 1
            # Never service a second message on this connection. Reject an
            # already-buffered pipeline; later extra bytes die with close.
            self.request.setblocking(False)
            try:
                if self.request.recv(1, socket.MSG_PEEK):
                    raise Rejected(400)
            except BlockingIOError:
                pass
            self.remaining_ingress()
            # JSON CPU work cannot be preempted here. Expiry is checked again
            # after parsing; this is not a hard end-to-end execution timeout.
            shape = inspect_json(body)
            self.remaining_ingress()
            status = 503
            record = {'status': status, 'endpoint': PATHS[start[1]],
                      'method': 'POST', 'body_bytes': size, 'body_frames': frames,
                      'header_bytes': len(header), 'shape': shape,
                      'authentication_present': any(k in headers for k in (b'authorization', b'x-api-key')),
                      'sse_accept': headers.get(b'accept') == b'text/event-stream'}
        except Rejected as e:
            status = e.status
            record = {'status': status}
        except socket.timeout:
            status, record = 408, {'status': 408}
        except (ValueError, OSError, RecursionError):
            status, record = 400, {'status': 400}
        # Only static failure cleanup may run after expiry. Accepted responses
        # never get a fresh timeout independent of the remaining lifetime.
        remaining = min(self.deadline, self.server.lifetime_deadline) - self.server.clock()
        if status == 503 and remaining <= 0:
            status, record = 408, {'status': 408}
        response_timeout = min(1.0, remaining) if remaining > 0 else 1.0
        payload = b'{"error":"probe_unsupported"}'
        response = ('HTTP/1.1 %d Probe\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n' % (status, len(payload))).encode() + payload
        try:
            self.request.settimeout(response_timeout)
            self.request.sendall(response)
        except OSError:
            pass
        # Recheck at retention, including time spent sending the static reply.
        if status == 503 and self.server.clock() >= min(self.deadline, self.server.lifetime_deadline):
            record = {'status': 408}
        if len(self.server.records) < self.server.max_connections:
            self.server.records.append(record)

FIELDS = frozenset(('model', 'messages', 'system', 'tools', 'tool_choice', 'stream',
                    'max_tokens', 'temperature', 'thinking', 'metadata', 'betas',
                    'context_management', 'output_config', 'stop_sequences'))

def _pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError('invalid_json')
        result[key] = value
    return result


def _constant(_):
    raise ValueError('invalid_json')


def inspect_json(body):
    if len(body) > 1048576:
        raise ValueError('body_limit')
    try:
        value = json.loads(body, object_pairs_hook=_pairs, parse_constant=_constant)
    except (UnicodeError, RecursionError, ValueError):
        raise ValueError('invalid_json') from None
    if not isinstance(value, dict) or any(k in value and not isinstance(value[k], list) for k in ('messages', 'tools')):
        raise ValueError('invalid_json')
    types = {dict: 'object', list: 'array', str: 'string', bool: 'boolean',
             int: 'number', float: 'number', type(None): 'null'}
    return {'fields': {k: types[type(v)] for k, v in value.items() if k in FIELDS},
            'unknown_field_count': sum(k not in FIELDS for k in value),
            'message_count': len(value.get('messages', [])),
            'tool_count': len(value.get('tools', []))}


def main():
    import argparse
    parser = argparse.ArgumentParser(description='Local-only metadata capture, never a model emulator')
    parser.add_argument('--duration', type=int, choices=range(1, 36), default=35)
    options = parser.parse_args()
    try:
        with CaptureServer(lifetime=options.duration) as server:
            while server.connections < server.max_connections and server.wire_bytes < server.max_wire:
                remaining = server.lifetime_deadline - server.clock()
                if remaining <= 0:
                    break
                server.timeout = min(0.1, remaining)
                server.handle_request()
            print(json.dumps({'schema': 1, 'fixture_only': True, 'records': server.records,
                              'ingress_bytes': server.wire_bytes}, separators=(',', ':')))
    except OSError:
        print('{"error":"capture_unavailable"}')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
