#!/usr/bin/env python3
"""Fixed loopback model fixture; the real guest CLI performs every tool action.

This script never executes the imported or exported project on the host. It
starts only the separately built/signed host probe. No provider or Keychain.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading


def wire_event(kind, **fields):
    return ('event: ' + kind + '\ndata: ' + json.dumps(dict(type=kind, **fields), separators=(',', ':')) + '\n\n').encode()


TOOLS = [
    ('Read', {'file_path': '/work/project/logic.py'}),
    ('Bash', {'command': 'python3 -B test_logic.py', 'description': 'Run the original test before the fix'}),
    ('Edit', {'file_path': '/work/project/logic.py', 'old_string': 'return a - b', 'new_string': 'return a + b'}),
    ('Bash', {'command': 'python3 -B test_logic.py', 'description': 'Run the unchanged original test after the fix'}),
]


def response(step, reflection=False):
    message_id = 'mini-sandbox-local-fixture-canary-86db9bd39f874753' if reflection else 'msg_fixture_' + str(step)
    result = wire_event('message_start', message=dict(id=message_id, type='message', role='assistant',
        model='deepseek-flash', content=[], stop_reason=None, stop_sequence=None, usage=dict(input_tokens=1, output_tokens=0)))
    if step < len(TOOLS):
        name, arguments = TOOLS[step]
        result += wire_event('content_block_start', index=0, content_block=dict(type='tool_use', id='tool_fixture_' + str(step), name=name, input={}))
        result += wire_event('content_block_delta', index=0, delta=dict(type='input_json_delta', partial_json=json.dumps(arguments, separators=(',', ':'))))
        reason = 'tool_use'
    else:
        result += wire_event('content_block_start', index=0, content_block=dict(type='text', text=''))
        result += wire_event('content_block_delta', index=0, delta=dict(type='text_delta', text='The original test failed before the arithmetic fix and passed after it.'))
        reason = 'end_turn'
    result += wire_event('content_block_stop', index=0)
    result += wire_event('message_delta', delta=dict(stop_reason=reason, stop_sequence=None), usage=dict(output_tokens=1))
    return result + wire_event('message_stop')


def main():
    serve_only = len(sys.argv) == 3 and sys.argv[1] == '--serve'
    if not serve_only and (len(sys.argv) not in (5, 6) or (len(sys.argv) == 6 and sys.argv[5] != 'reflection')):
        raise SystemExit('usage: business_fixture.py SIGNED_HOST BUSINESS_IMAGE VENDOR_DISK NEW_EVIDENCE_DIRECTORY [reflection] | --serve NEW_EVIDENCE_DIRECTORY')
    reflection = not serve_only and len(sys.argv) == 6
    if not serve_only:
        host, image, vendor = map(lambda v: str(Path(v).absolute()), sys.argv[1:4])
    root = Path(sys.argv[2] if serve_only else sys.argv[4]).absolute()
    os.umask(0o077)
    root.mkdir(mode=0o700)
    session = root / 'session'; session.mkdir(mode=0o700)
    state = {'requests': 0, 'tool_results': [], 'errors': []}
    completed = threading.Event()
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_):
            pass
        def do_POST(self):
            try:
                step = state['requests']
                if self.path != '/anthropic/v1/messages?beta=true' or step >= (1 if reflection else 5):
                    raise ValueError('fixture route/count')
                count = int(self.headers.get('Content-Length', '0'))
                if not 0 < count <= 65536 or self.headers.get('Transfer-Encoding'):
                    raise ValueError('fixture framing')
                data = self.rfile.read(count)
                if len(data) != count:
                    raise ValueError('fixture truncated request')
                request = json.loads(data)
                if request.get('model') != 'deepseek-flash' or request.get('stream') is not True:
                    raise ValueError('fixture model')
                (root / ('request-' + str(step) + '.json')).write_bytes(data)
                if step:
                    matches = [block for message in request['messages'] if isinstance(message.get('content'), list)
                               for block in message['content'] if block.get('type') == 'tool_result' and block.get('tool_use_id') == 'tool_fixture_' + str(step - 1)]
                    if len(matches) != 1:
                        raise ValueError('missing real CLI tool_result')
                    block = matches[0]
                    content = json.dumps(block.get('content'), ensure_ascii=False, sort_keys=True)
                    if step == 1 and 'return a - b' not in content:
                        raise ValueError('read did not return imported file')
                    if step == 2 and ('AssertionError' not in content or block.get('is_error') is not True):
                        raise ValueError('original test did not fail')
                    if step in (3, 4) and block.get('is_error') is True:
                        raise ValueError('edit or unchanged test failed')
                    state['tool_results'].append({'id': block['tool_use_id'], 'is_error': block.get('is_error', False),
                        'content_sha256': hashlib.sha256(content.encode()).hexdigest(), 'content_bytes': len(content.encode())})
                body = response(step, reflection)
                state['requests'] += 1
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Connection', 'close')
                self.end_headers(); self.wfile.write(body); self.wfile.flush()
            except Exception as error:
                state['errors'].append(type(error).__name__ + ': ' + str(error))
                self.send_error(400, 'fixture validation failed')
            finally:
                self.close_connection = True
                if state['requests'] == 5 or state['errors']:
                    completed.set()
    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
    try:
        if serve_only:
            ready = {'port': server.server_port, 'scope': 'local scripted provider only; App approvals remain manual'}
            (root / 'ready.json').write_text(json.dumps(ready) + '\n')
            print(json.dumps(ready), flush=True)
            state['completed_within_deadline'] = completed.wait(1800)
        else:
            with (root / 'host.log').open('w') as output:
                run = subprocess.run([host, image, vendor, str(session), str(server.server_port)] + (['reflection'] if reflection else []),
                    stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT, timeout=180)
            state['host_exit'] = run.returncode
    finally:
        server.shutdown(); server.server_close(); worker.join(timeout=5)
        (root / 'fixture.json').write_text(json.dumps(state, indent=2) + '\n')
    print(json.dumps(state, sort_keys=True))
    if state.get('host_exit', 0) or state['requests'] != (1 if reflection else 5) or len(state['tool_results']) != (0 if reflection else 4) or state['errors']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
