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

    def __init__(self, address=('127.0.0.1', 4061), *, lifetime=35.0, clock=None, structural_metrics_enabled=False):
        if address[0] != '127.0.0.1':
            raise ValueError('loopback_only')
        self.records = []
        self.structural_metrics_enabled = structural_metrics_enabled
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
            metrics = structural_metrics(body) if self.server.structural_metrics_enabled else None
            shape = inspect_json(body)
            self.remaining_ingress()
            status = 503
            record = {'status': status, 'endpoint': PATHS[start[1]],
                      'method': 'POST', 'body_bytes': size, 'body_frames': frames,
                      'header_bytes': len(header), 'shape': shape,
                      'authentication_present': any(k in headers for k in (b'authorization', b'x-api-key')),
                      'sse_accept': headers.get(b'accept') == b'text/event-stream'}
            if metrics is not None:
                record['metrics'] = metrics
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
        # Opt-in output stays within the existing supervisor's 16 KiB pipe cap.
        # Reserve room for all remaining fixed omission records and the wrapper.
        if self.server.structural_metrics_enabled and len(json.dumps(self.server.records + [record], separators=(',', ':')).encode()) > 15000:
            record = {'status': record['status'], 'metrics_omitted': True}
        # Recheck at retention, including time spent sending/serializing.
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


METRICS_NODE_CAP = 32768
METRICS_DEPTH_CAP = 64
SAFE_INTEGER = 9007199254740991


class _NumericToken(str):
    """Transient spelling only, never returned by the metrics serializer."""


def _metric_integer(token):
    if token == '-0' or len(token.lstrip('-')) > 16:
        return _NumericToken(token)
    value = int(token)
    return value if abs(value) <= SAFE_INTEGER else _NumericToken(token)


def _string_bytes(value):
    # Compact UTF-8 JSON string bytes without constructing serialized text.
    size = 2
    for char in value:
        n = ord(char)
        if 0xD800 <= n <= 0xDFFF:
            raise ValueError('invalid_json')
        size += 2 if char in '"\\\b\f\n\r\t' else 6 if n < 32 else 1 if n < 128 else 2 if n < 2048 else 3 if n < 65536 else 4
    return size


def _metric_stats(value):
    # Root is depth zero; keys are bytes, not value nodes (ModelJSON).
    stack = [(value, 0)]
    nodes = depth = size = noninteger = unsafe = 0
    while stack:
        item, level = stack.pop()
        nodes += 1
        if nodes > METRICS_NODE_CAP or level > METRICS_DEPTH_CAP:
            raise ValueError('metrics_limit')
        depth = max(depth, level)
        if isinstance(item, (dict, list)):
            children = item.values() if isinstance(item, dict) else item
            if nodes + len(stack) + len(item) > METRICS_NODE_CAP:
                raise ValueError('metrics_limit')
            size += 2 + max(0, len(item) - 1)
            if isinstance(item, dict):
                size += sum(_string_bytes(k) + 1 for k in item)
            stack.extend((child, level + 1) for child in children)
        elif isinstance(item, _NumericToken):
            size += len(item)
            if item == '-0' or any(c in item for c in '.eE'):
                noninteger += 1
            else:
                unsafe += 1
        elif isinstance(item, str):
            size += _string_bytes(item)
        else:
            size += len(json.dumps(item))
        if size > BODY_CAP:
            raise ValueError('metrics_limit')
    return size, depth, nodes, noninteger, unsafe


def _metric_load(body):
    if len(body) > BODY_CAP:
        raise ValueError('body_limit')
    # Bound JSON decoder recursion before parsing; delimiters in strings don't count.
    level = 0
    quoted = escaped = False
    for byte in body:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):
            level += 1
            if level > METRICS_DEPTH_CAP + 1:
                raise ValueError('metrics_limit')
        elif byte in (93, 125):
            level -= 1
    try:
        value = json.loads(body, object_pairs_hook=_pairs, parse_constant=_constant,
                           parse_int=_metric_integer, parse_float=_NumericToken)
        if not isinstance(value, dict) or any(k in value and not isinstance(value[k], list) for k in ('messages', 'tools')):
            raise ValueError('invalid_json')
        _metric_stats(value)
        return value
    except (UnicodeError, RecursionError):
        raise ValueError('invalid_json') from None
    except ValueError as error:
        if str(error) == 'metrics_limit':
            raise
        raise ValueError('invalid_json') from None


def structural_metrics(body):
    """Opt-in fixed-label metrics. No names, text, IDs or arbitrary keys escape."""
    value = _metric_load(body)
    def integer(v):
        return v if type(v) is int and 0 <= v <= SAFE_INTEGER else 'invalid'
    def enum(v, allowed):
        return v if type(v) is str and v in allowed else 'unknown'
    def typename(v):
        return {dict: 'object', list: 'array', str: 'string', bool: 'boolean',
                int: 'number', _NumericToken: 'number', type(None): 'null'}[type(v)]
    thinking = value.get('thinking', {})
    output = value.get('output_config', {})
    system = value.get('system', [])
    items = system if isinstance(system, list) else [system]
    sysmetrics = {'type': typename(system) if 'system' in value else 'absent', 'count': len(items),
                  'text_count': 0, 'text_bytes': 0, 'text_bytes_max': 0,
                  'cache_control_present': 0, 'unknown_type_count': 0, 'unknown_field_count': 0}
    for item in items:
        if isinstance(item, dict):
            sysmetrics['unknown_field_count'] += sum(k not in ('type', 'text', 'cache_control') for k in item)
            sysmetrics['cache_control_present'] += 'cache_control' in item
            sysmetrics['unknown_type_count'] += item.get('type') != 'text'
            text = item.get('text')
        else:
            text = item
            sysmetrics['unknown_type_count'] += type(item) is not str
        if type(text) is str:
            n = len(text.encode('utf-8'))
            sysmetrics['text_count'] += 1
            sysmetrics['text_bytes'] += n
            sysmetrics['text_bytes_max'] = max(sysmetrics['text_bytes_max'], n)
    tools = value.get('tools', [])
    fields = ('name', 'description', 'input_schema', 'type', 'cache_control')
    metrics: dict[str, int] = dict.fromkeys(('count', 'name_max', 'name_invalid_count', 'duplicate_name_count',
                            'description_max', 'schema_bytes_max', 'schema_depth_max', 'schema_nodes_max',
                            'schema_noninteger_count', 'schema_unsafe_integer_count', 'schema_nonobject_count',
                            'unknown_field_count', 'nonobject_count'), 0)
    metrics.update({k + '_present': 0 for k in fields})
    metrics['count'] = len(tools)
    names = set()
    for tool in tools:
        if not isinstance(tool, dict):
            metrics['nonobject_count'] += 1
            continue
        metrics['unknown_field_count'] += sum(k not in fields for k in tool)
        for key in fields:
            metrics[key + '_present'] += key in tool
        name = tool.get('name')
        if type(name) is str:
            metrics['name_max'] = max(metrics['name_max'], len(name.encode('utf-8')))
            metrics['duplicate_name_count'] += name in names
            names.add(name)
        metrics['name_invalid_count'] += type(name) is not str or re.fullmatch(r'[A-Za-z0-9_-]{1,64}', name) is None
        description = tool.get('description')
        if type(description) is str:
            metrics['description_max'] = max(metrics['description_max'], len(description.encode('utf-8')))
        if 'input_schema' in tool:
            schema = tool['input_schema']
            size, depth, nodes, noninteger, unsafe = _metric_stats(schema)
            for key, n in (('schema_bytes_max', size), ('schema_depth_max', depth), ('schema_nodes_max', nodes)):
                metrics[key] = max(metrics[key], n)
            metrics['schema_noninteger_count'] += noninteger
            metrics['schema_unsafe_integer_count'] += unsafe
            metrics['schema_nonobject_count'] += type(schema) is not dict
    result = {'stream': value.get('stream') if type(value.get('stream')) is bool else 'invalid',
              'max_tokens': integer(value.get('max_tokens')),
              'thinking': enum(thinking.get('type'), ('enabled', 'disabled', 'adaptive')) if isinstance(thinking, dict) else 'invalid',
              'thinking_budget': integer(thinking.get('budget_tokens')) if isinstance(thinking, dict) else 'invalid',
              'effort': enum(output.get('effort'), ('low', 'medium', 'high', 'max')) if isinstance(output, dict) else 'invalid',
              'system': sysmetrics, 'tools': metrics, 'mismatches': []}
    if 'thinking' not in value:
        result['thinking'] = 'absent'
    if isinstance(thinking, dict) and 'budget_tokens' not in thinking:
        result['thinking_budget'] = 'absent'
    if isinstance(output, dict) and 'effort' not in output:
        result['effort'] = 'absent'
    result['thinking_unknown_field_count'] = sum(k not in ('type', 'budget_tokens') for k in thinking) if isinstance(thinking, dict) else 0
    result['output_unknown_field_count'] = sum(k != 'effort' for k in output) if isinstance(output, dict) else 0
    checks = {'max_tokens': type(result['max_tokens']) is not int or not 1 <= result['max_tokens'] <= 8192,
              'tool_description_bytes': metrics['description_max'] > 4096,
              'thinking': 'thinking' in value and result['thinking'] != 'disabled',
              'messages': len(value.get('messages', [])) > 128, 'tools': len(tools) > 64,
              'tool_name': metrics['name_invalid_count'] > 0 or metrics['duplicate_name_count'] > 0,
              'schema_bytes': metrics['schema_bytes_max'] > 65536,
              'schema_depth': metrics['schema_depth_max'] > 32,
              'schema_nodes': metrics['schema_nodes_max'] > 8192,
              'schema_numeric_domain': metrics['schema_noninteger_count'] > 0 or metrics['schema_unsafe_integer_count'] > 0,
              'schema_root': metrics['schema_nonobject_count'] > 0,
              'system_blocks': isinstance(system, list) and len(system) > 0}
    checks.update({key: key in value for key in ('metadata', 'context_management', 'output_config')})
    result['mismatches'] = [key for key, mismatch in checks.items() if mismatch]
    return result


def main():
    import argparse
    parser = argparse.ArgumentParser(description='Local-only metadata capture, never a model emulator')
    parser.add_argument('--duration', type=int, choices=range(1, 36), default=35)
    parser.add_argument('--structural-metrics', action='store_true', help='bounded fixed-label measurements only')
    options = parser.parse_args()
    try:
        with CaptureServer(lifetime=options.duration, structural_metrics_enabled=options.structural_metrics) as server:
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
