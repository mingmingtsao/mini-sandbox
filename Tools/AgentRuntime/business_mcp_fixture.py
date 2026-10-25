#!/usr/bin/env python3
"""Actual CLI MCP driver with owned loopback model and repository services.

The upstream repository deliberately permits A and B. Host grants permit only
A; fake host credentials travel over stdin to the host probe, never the VM.
"""
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import threading
from business_fixture import wire_event


def main():
    serve_only = len(sys.argv) == 4 and sys.argv[1] == '--serve'
    modes = ('mcp-read', 'mcp-write', 'mcp-denied-resource', 'mcp-denied-write')
    if (not serve_only and len(sys.argv) != 6) or sys.argv[-1] not in modes:
        raise SystemExit('usage: business_mcp_fixture.py SIGNED_HOST BUSINESS_IMAGE VENDOR_DISK NEW_EVIDENCE MODE | --serve NEW_EVIDENCE MODE')
    if not serve_only:
        host, image, vendor = map(lambda value: str(Path(value).absolute()), sys.argv[1:4])
    root = Path(sys.argv[2] if serve_only else sys.argv[4]).absolute(); mode = sys.argv[-1]
    os.umask(0o077); root.mkdir(mode=0o700)
    session = root / 'session'; session.mkdir(mode=0o700)
    source = Path(__file__).resolve().parents[2] / 'Tests/MCPGatewayChecks/claude_loopback.py'
    spec = importlib.util.spec_from_file_location('local_mcp_fixture', source)
    mcp = importlib.util.module_from_spec(spec); spec.loader.exec_module(mcp)
    # Matches the public SANDBOX_TEST_FIXTURES-only App configuration. It is
    # deliberately not a personal credential; normal probes remain randomized.
    token = 'mini-sandbox-local-mcp-fixture-canary-39f2e5b7' if serve_only else 'mcp-canary-' + secrets.token_hex(24)
    state = dict(lock=threading.Lock(), token=token, hits=0, writes=0,
                 repos={'A': 'repo-A-initial', 'B': 'repo-B-initial'}, mode='normal', calls=[])
    completed = threading.Event()
    interrupted = threading.Event()
    if serve_only:
        def stop_services(_signum, _frame):
            interrupted.set(); completed.set()
        signal.signal(signal.SIGINT, stop_services)
        signal.signal(signal.SIGTERM, stop_services)
    class RepositoryHandler(mcp.Handler):
        def setup(self):
            super().setup(); self.connection.settimeout(5)
        def do_POST(self):
            count = int(self.headers.get('Content-Length', '0'))
            if not 0 < count <= 65536:
                self.send_error(400); return
            body = self.rfile.read(count)
            request = json.loads(body)
            with state['lock']:
                state['calls'].append({'method': request.get('method'), 'name': request.get('params', {}).get('name'),
                                       'repo': request.get('params', {}).get('arguments', {}).get('repo')})
            self.rfile = io.BytesIO(body)
            super().do_POST()
    repository = mcp.Server(('127.0.0.1', 0), RepositoryHandler); repository.state = state
    repo_thread = threading.Thread(target=repository.serve_forever, daemon=True); repo_thread.start()
    model_state = {'requests': 0, 'results': [], 'errors': []}
    write = mode in ('mcp-write', 'mcp-denied-write')
    name = 'mcp__sandbox__repo_write' if write else 'mcp__sandbox__repo_read'
    arguments = {'repo': 'B' if mode == 'mcp-denied-resource' else 'A'}
    if write: arguments['content'] = 'vm-approved-once'
    denied = mode in ('mcp-denied-resource', 'mcp-denied-write')
    class ModelHandler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def setup(self):
            super().setup(); self.connection.settimeout(5)
        def log_message(self, *_): pass
        def do_POST(self):
            try:
                step = model_state['requests']
                count = int(self.headers.get('Content-Length', '0'))
                if step >= 2 or self.path != '/anthropic/v1/messages?beta=true' or not 0 < count <= 65536 or self.headers.get('Transfer-Encoding'):
                    raise ValueError('model route/count')
                raw = self.rfile.read(count)
                if state['token'].encode() in raw: raise ValueError('MCP credential reached model')
                request = json.loads(raw); (root / ('model-request-' + str(step) + '.json')).write_bytes(raw)
                if name not in {tool['name'] for tool in request['tools']}:
                    raise ValueError('actual CLI did not expose selected MCP tool')
                if step:
                    results = [block for message in request['messages'] if isinstance(message.get('content'), list)
                               for block in message['content'] if block.get('type') == 'tool_result' and block.get('tool_use_id') == 'mcp_fixture_0']
                    if len(results) != 1: raise ValueError('missing actual MCP tool_result')
                    result = results[0]; content = json.dumps(result.get('content'), sort_keys=True)
                    if denied:
                        if result.get('is_error') is not True: raise ValueError('host denial did not reach actual CLI as failure')
                    elif result.get('is_error') is True or ('vm-approved-once' if write else 'repo-A-initial') not in content:
                        raise ValueError('actual MCP result mismatch')
                    model_state['results'].append({'is_error': result.get('is_error', False), 'content': content})
                body = wire_event('message_start', message=dict(id='msg_mcp_' + str(step), type='message', role='assistant',
                    model='deepseek-flash', content=[], stop_reason=None, stop_sequence=None, usage=dict(input_tokens=1, output_tokens=0)))
                if not step:
                    body += wire_event('content_block_start', index=0, content_block=dict(type='tool_use', id='mcp_fixture_0', name=name, input={}))
                    body += wire_event('content_block_delta', index=0, delta=dict(type='input_json_delta', partial_json=json.dumps(arguments, separators=(',', ':'))))
                else:
                    body += wire_event('content_block_start', index=0, content_block=dict(type='text', text=''))
                    body += wire_event('content_block_delta', index=0, delta=dict(type='text_delta', text='The requested bounded MCP check finished.'))
                body += wire_event('content_block_stop', index=0)
                body += wire_event('message_delta', delta=dict(stop_reason='tool_use' if not step else 'end_turn', stop_sequence=None), usage=dict(output_tokens=1))
                body += wire_event('message_stop'); model_state['requests'] += 1
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(body))); self.send_header('Connection', 'close'); self.end_headers()
                self.wfile.write(body); self.wfile.flush()
            except Exception as error:
                model_state['errors'].append(type(error).__name__ + ': ' + str(error)); self.send_error(400, 'fixture validation failed')
            finally:
                self.close_connection = True
                if model_state['requests'] == 2 or model_state['errors']: completed.set()
    model = http.server.HTTPServer(('127.0.0.1', 0), ModelHandler)
    model_thread = threading.Thread(target=model.serve_forever, daemon=True); model_thread.start()
    try:
        if serve_only:
            ready = {'modelPort': model.server_port, 'mcpPort': repository.server_port, 'mode': mode,
                     'maximumSeconds': 1800, 'scope': 'owned loopback fixtures only; App grants and approvals remain manual'}
            (root / 'ready.json').write_text(json.dumps(ready, indent=2) + '\n')
            print(json.dumps(ready, sort_keys=True), flush=True)
            finished_before_deadline = completed.wait(1800)
            with state['lock']:
                calls = list(state['calls']); writes = state['writes']; repos = dict(state['repos']); hits = state['hits']
            observations = {'scope': 'service observations only; inspect App evidence separately', 'mode': mode,
                            'finished_before_deadline': finished_before_deadline, 'interrupted': interrupted.is_set(),
                            'upstream_hits': hits, 'upstream_calls': calls, 'upstream_writes': writes,
                            'resource_B_unchanged': repos['B'] == 'repo-B-initial', 'model': model_state}
            (root / 'fixture.json').write_text(json.dumps(observations, indent=2) + '\n')
            print(json.dumps(observations, sort_keys=True), flush=True)
            return 0 if not model_state['errors'] else 1
        config = json.dumps({'port': repository.server_port, 'token': state['token']}) + '\n'
        with (root / 'host.log').open('w') as out:
            run = subprocess.run([host, image, vendor, str(session), str(model.server_port), mode], input=config,
                text=True, stdout=out, stderr=subprocess.STDOUT, timeout=180)
        log = (root / 'host.log').read_text()
        if state['token'] in log: raise RuntimeError('fake credential appeared in host output')
        with state['lock']:
            calls = list(state['calls']); writes = state['writes']; repos = dict(state['repos']); hits = state['hits']
        call_count = len([call for call in calls if call['method'] == 'tools/call'])
        early_denied = mode == 'mcp-denied-resource'
        valid = (run.returncode == 0 and model_state['requests'] == (1 if early_denied else 2) and len(model_state['results']) == (0 if early_denied else 1) and not model_state['errors']
                 and all(call['repo'] != 'B' for call in calls) and call_count == (0 if denied else 1)
                 and writes == (1 if mode == 'mcp-write' else 0) and repos['B'] == 'repo-B-initial')
        result = {'status': 'PASS' if valid else 'FAIL', 'mode': mode, 'host_exit': run.returncode, 'upstream_hits': hits,
                  'upstream_calls': calls, 'upstream_writes': writes, 'resource_B_unchanged': repos['B'] == 'repo-B-initial', 'model': model_state}
        (root / 'fixture.json').write_text(json.dumps(result, indent=2) + '\n'); print(json.dumps(result, sort_keys=True))
        return 0 if valid else 1
    finally:
        model.shutdown(); model.server_close(); model_thread.join(timeout=2)
        repository.shutdown(); repository.server_close(); repo_thread.join(timeout=2)


if __name__ == '__main__':
    raise SystemExit(main())
